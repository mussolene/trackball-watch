import SwiftUI

struct ContentView: View {
    var body: some View {
        TrackballView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .crownScrollHandler()
            .ignoresSafeArea()
    }
}
