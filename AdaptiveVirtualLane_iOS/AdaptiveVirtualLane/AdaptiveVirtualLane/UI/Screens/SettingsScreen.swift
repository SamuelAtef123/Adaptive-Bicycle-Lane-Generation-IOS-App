import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var showKeySaved = false

    var body: some View {
        NavigationStack {
            Form {
                // API Key
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TomTom API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("Enter API key", text: $appState.tomTomAPIKey)
                            .font(.system(size: 14, design: .monospaced))
                        Text("Get a free key at developer.tomtom.com")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } header: { Text("Navigation Services") }

                // Performance
                Section {
                    Stepper("Keyframe Interval: \(appState.keyframeInterval)",
                            value: $appState.keyframeInterval, in: 1...15)

                    VStack(alignment: .leading) {
                        Text("Bike Lane Confidence: \(Int(appState.bikeLaneConfidenceThreshold * 100))%")
                        Slider(value: $appState.bikeLaneConfidenceThreshold, in: 0.3...0.9, step: 0.05)
                    }

                    VStack(alignment: .leading) {
                        Text("Obstacle Confidence: \(Int(appState.obstacleConfidenceThreshold * 100))%")
                        Slider(value: $appState.obstacleConfidenceThreshold, in: 0.2...0.8, step: 0.05)
                    }

                    VStack(alignment: .leading) {
                        Text("Road Type Confidence: \(Int(appState.roadTypeConfidenceThreshold * 100))%")
                        Slider(value: $appState.roadTypeConfidenceThreshold, in: 0.4...0.9, step: 0.05)
                    }
                } header: { Text("Detection Parameters") }

                // Model info
                Section {
                    InfoRow(label: "Bike Lane Model",     value: "YOLO26n-Seg")
                    InfoRow(label: "Obstacle Model",      value: "YOLO26n (COCO)")
                    InfoRow(label: "Drivable Area",       value: "TwinLiteNet+ Medium")
                    InfoRow(label: "Depth Estimation",    value: "Depth Anything V2 Small")
                    InfoRow(label: "Road Classification", value: "YOLO26n-cls")
                    InfoRow(label: "Traffic API",         value: "TomTom Platform")
                } header: { Text("System Models") }

                // Lane widths reference
                Section {
                    InfoRow(label: "One-Way + Low Traffic",      value: "1.8 m")
                    InfoRow(label: "One-Way + Med/High Traffic",  value: "1.6 m")
                    InfoRow(label: "Two-Way + Low Traffic",       value: "1.4 m")
                    InfoRow(label: "Two-Way + Med/High Traffic",  value: "1.2 m (AASHTO min)")
                } header: { Text("Adaptive Lane Widths") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        appState.saveSettings()
                        showKeySaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if showKeySaved {
                    Text("✓ Settings saved")
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Color.green).cornerRadius(10)
                        .foregroundColor(.white).fontWeight(.semibold)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut, value: showKeySaved)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(.primary)
            Spacer()
            Text(value).foregroundColor(.secondary).font(.system(size: 13))
        }
    }
}
