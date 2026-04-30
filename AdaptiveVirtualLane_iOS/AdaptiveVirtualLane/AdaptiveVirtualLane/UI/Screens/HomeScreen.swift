import SwiftUI

struct HomeScreen: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSettings: Bool
    @State private var destination = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.10, blue: 0.18),
                         Color(red: 0.08, green: 0.18, blue: 0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "bicycle")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundColor(.green)
                        .padding(.top, 60)

                    Text("Adaptive Virtual Lane")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Smart E-Bike Navigation")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.bottom, 48)

                // Destination input card
                VStack(alignment: .leading, spacing: 12) {
                    Label("Enter Destination", systemImage: "mappin.and.ellipse")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.green.opacity(0.9))

                    TextField("e.g. German University in Cairo", text: $destination)
                        .focused($isFocused)
                        .padding(14)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                        .font(.system(size: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isFocused ? Color.green : Color.white.opacity(0.15), lineWidth: 1.5)
                        )
                        .submitLabel(.go)
                        .onSubmit { startNavigation() }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

                // API key warning
                if appState.tomTomAPIKey.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("No TomTom API key set — offline mode")
                            .font(.system(size: 12))
                            .foregroundColor(.yellow.opacity(0.9))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                // Start button
                Button(action: startNavigation) {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        Text("Start Navigation")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(colors: [.green, Color(red: 0.1, green: 0.7, blue: 0.3)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(14)
                    .foregroundColor(.white)
                    .font(.system(size: 17))
                }
                .padding(.horizontal, 24)
                .shadow(color: .green.opacity(0.4), radius: 12, y: 4)

                Spacer()

                // Feature pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        FeaturePill(icon: "eye.fill",           label: "Computer Vision")
                        FeaturePill(icon: "ruler",              label: "Metric Depth")
                        FeaturePill(icon: "waveform.path",      label: "Real-time AI")
                        FeaturePill(icon: "car.fill",           label: "Obstacle Avoidance")
                        FeaturePill(icon: "antenna.radiowaves.left.and.right", label: "Traffic-Aware")
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 32)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func startNavigation() {
        appState.destination = destination
        appState.isNavigating = true
        isFocused = false
    }
}

struct FeaturePill: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.08))
        .cornerRadius(20)
        .foregroundColor(.white.opacity(0.75))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}
