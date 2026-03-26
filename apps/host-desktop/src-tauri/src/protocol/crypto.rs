//! AES-128-GCM encryption for TBP packets.
//!
//! Key exchange: X25519 ECDH.
//! Key derivation: HKDF-SHA256 with salt "TBP-v1".
//! Encryption: AES-128-GCM.
//! Nonce: 12 bytes — [seq as u32 LE (4 bytes)] ++ [timestamp_us as u64 LE (8 bytes)].
//! AAD: packet header bytes (8 bytes).

use aes_gcm::{
    aead::{Aead, KeyInit, OsRng},
    Aes128Gcm, Key, Nonce,
};
use hkdf::Hkdf;
use sha2::Sha256;
use x25519_dalek::{EphemeralSecret, PublicKey, SharedSecret};

use crate::protocol::packets::PacketHeader;

const HKDF_SALT: &[u8] = b"TBP-v1";
const HKDF_INFO: &[u8] = b"aes-128-gcm-key";
const KEY_LEN: usize = 16; // AES-128

/// ECDH keypair for pairing.
pub struct EcdhKeypair {
    secret: EphemeralSecret,
    pub public: PublicKey,
}

impl EcdhKeypair {
    /// Generate a new ephemeral X25519 keypair.
    pub fn generate() -> Self {
        let secret = EphemeralSecret::random_from_rng(OsRng);
        let public = PublicKey::from(&secret);
        Self { secret, public }
    }

    /// Derive the session key from the peer's public key.
    /// Consumes self (ephemeral secret can only be used once).
    pub fn derive_session_key(self, peer_public: &[u8; 32]) -> Result<SessionKey, CryptoError> {
        let peer_pub = PublicKey::from(*peer_public);
        let shared: SharedSecret = self.secret.diffie_hellman(&peer_pub);
        SessionKey::from_shared_secret(shared.as_bytes())
    }
}

/// Derived AES-128-GCM session key.
#[derive(Clone)]
pub struct SessionKey {
    cipher: Aes128Gcm,
}

impl SessionKey {
    fn from_shared_secret(shared: &[u8]) -> Result<Self, CryptoError> {
        let hkdf = Hkdf::<Sha256>::new(Some(HKDF_SALT), shared);
        let mut okm = [0u8; KEY_LEN];
        hkdf.expand(HKDF_INFO, &mut okm)
            .map_err(|_| CryptoError::KeyDerivation)?;
        let key = Key::<Aes128Gcm>::from_slice(&okm);
        Ok(Self {
            cipher: Aes128Gcm::new(key),
        })
    }

    /// Encrypt `plaintext` using the packet header as AAD.
    ///
    /// Returns ciphertext || tag (16 extra bytes).
    pub fn encrypt(
        &self,
        header: &PacketHeader,
        plaintext: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let nonce = make_nonce(header.seq, header.timestamp_us);
        let aad = make_aad(header)?;
        self.cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                aes_gcm::aead::Payload {
                    msg: plaintext,
                    aad: &aad,
                },
            )
            .map_err(|_| CryptoError::Encrypt)
    }

    /// Decrypt `ciphertext` using the packet header as AAD.
    pub fn decrypt(
        &self,
        header: &PacketHeader,
        ciphertext: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let nonce = make_nonce(header.seq, header.timestamp_us);
        let aad = make_aad(header)?;
        self.cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                aes_gcm::aead::Payload {
                    msg: ciphertext,
                    aad: &aad,
                },
            )
            .map_err(|_| CryptoError::Decrypt)
    }
}

/// Build the 12-byte nonce: [seq u32 LE (4 bytes)] ++ [timestamp_us u64 LE (8 bytes)].
fn make_nonce(seq: u16, timestamp_us: u32) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    nonce[..4].copy_from_slice(&(seq as u32).to_le_bytes());
    nonce[4..12].copy_from_slice(&(timestamp_us as u64).to_le_bytes());
    nonce
}

/// Serialize the header as AAD using bincode.
fn make_aad(header: &PacketHeader) -> Result<Vec<u8>, CryptoError> {
    crate::protocol::packets::encode_header(header).map_err(|_| CryptoError::Encode)
}

// ── Errors ────────────────────────────────────────────────────────────────────

#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("key derivation failed")]
    KeyDerivation,
    #[error("encryption failed")]
    Encrypt,
    #[error("decryption failed (bad key or tampered data)")]
    Decrypt,
    #[error("header encoding failed")]
    Encode,
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::packets::{packet_type, PacketHeader};

    fn sample_header() -> PacketHeader {
        PacketHeader {
            seq: 1,
            packet_type: packet_type::TOUCH,
            flags: PacketHeader::ENCRYPTED,
            timestamp_us: 999_000,
        }
    }

    fn make_session_pair() -> (SessionKey, SessionKey) {
        let alice = EcdhKeypair::generate();
        let bob = EcdhKeypair::generate();
        let alice_pub = *alice.public.as_bytes();
        let bob_pub = *bob.public.as_bytes();
        let alice_key = alice.derive_session_key(&bob_pub).unwrap();
        let bob_key = bob.derive_session_key(&alice_pub).unwrap();
        (alice_key, bob_key)
    }

    #[test]
    fn ecdh_shared_secret_matches() {
        // Both sides must derive the same key.
        let (alice_key, bob_key) = make_session_pair();
        let header = sample_header();
        let plaintext = b"hello trackball";

        let ct = alice_key.encrypt(&header, plaintext).unwrap();
        let pt = bob_key.decrypt(&header, &ct).unwrap();
        assert_eq!(&pt, plaintext);
    }

    #[test]
    fn encrypt_decrypt_round_trip() {
        let (key, _) = make_session_pair();
        let header = sample_header();
        let data = b"touch x=1234 y=-5678 pressure=200";

        let ct = key.encrypt(&header, data).unwrap();
        assert_ne!(&ct[..data.len()], data.as_slice()); // ciphertext differs
        let pt = key.decrypt(&header, &ct).unwrap();
        assert_eq!(&pt, data);
    }

    #[test]
    fn tampered_ciphertext_rejected() {
        let (key, _) = make_session_pair();
        let header = sample_header();
        let mut ct = key.encrypt(&header, b"secret data").unwrap();
        ct[0] ^= 0xFF; // flip first byte
        assert!(key.decrypt(&header, &ct).is_err());
    }

    #[test]
    fn wrong_header_as_aad_rejected() {
        let (key, _) = make_session_pair();
        let header = sample_header();
        let ct = key.encrypt(&header, b"data").unwrap();

        let wrong_header = PacketHeader { seq: 999, ..header };
        assert!(key.decrypt(&wrong_header, &ct).is_err());
    }

    #[test]
    fn nonce_varies_with_seq() {
        let n1 = make_nonce(1, 1000);
        let n2 = make_nonce(2, 1000);
        assert_ne!(n1, n2);
    }
}
