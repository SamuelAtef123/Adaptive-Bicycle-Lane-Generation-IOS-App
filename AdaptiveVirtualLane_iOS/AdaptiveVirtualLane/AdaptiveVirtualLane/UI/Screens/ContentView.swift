import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            if appState.isNavigating {
                CameraScreen()
                    .environmentObject(appState)
            } else {
                HomeScreen(showSettings: $showSettings)
                    .environmentObject(appState)
                    .sheet(isPresented: $showSettings) {
                        SettingsScreen()
                            .environmentObject(appState)
                    }
            }
        }
        .onAppear { appState.loadSettings() }
    }
}
