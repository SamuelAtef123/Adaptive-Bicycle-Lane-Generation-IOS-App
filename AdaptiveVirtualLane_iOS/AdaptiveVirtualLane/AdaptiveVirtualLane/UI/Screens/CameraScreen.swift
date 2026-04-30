import SwiftUI
import AVFoundation
import Combine

struct CameraScreen: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = CameraScreenViewModel()
    @State private var showStopAlert = false

    var body: some View {
        ZStack {
            // Camera feed + overlay
            CameraPreviewRepresentable(
                previewLayer: viewModel.previewLayer,
                renderState: $viewModel.renderState
            )
            .ignoresSafeArea()

            // Top bar
            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.start(destination: appState.destination,
                            apiKey: appState.tomTomAPIKey,
                            keyframeInterval: appState.keyframeInterval,
                            bikeLaneConf: appState.bikeLaneConfidenceThreshold,
                            obstacleConf: appState.obstacleConfidenceThreshold,
                            roadTypeConf: appState.roadTypeConfidenceThreshold)
        }
        .onDisappear { viewModel.stop() }
        .alert("Stop Navigation?", isPresented: $showStopAlert) {
            Button("Stop", role: .destructive) {
                viewModel.stop()
                appState.isNavigating = false
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Back button
            Button {
                showStopAlert = true
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            Spacer()

            // Status pill
            Text(viewModel.statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .cornerRadius(20)

            Spacer()

            // Intersection maneuver indicator
            if viewModel.renderState.intersectionMode {
                ManeuverIcon(maneuver: viewModel.renderState.upcomingManeuver)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 56)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            // Lane width indicator
            if let decision = viewModel.renderState.laneDecision {
                StatBadge(
                    icon: "ruler",
                    value: String(format: "%.1fm", decision.finalWidth),
                    label: "Lane",
                    color: decision.isNarrowRoad ? .red : .green
                )
            }

            // Traffic indicator
            if let traffic = viewModel.renderState.trafficLevel {
                StatBadge(
                    icon: "car.fill",
                    value: traffic.rawValue,
                    label: "Traffic",
                    color: traffic == .low ? .green : traffic == .medium ? .yellow : .red
                )
            }

            // Road type
            if let road = viewModel.renderState.roadType {
                StatBadge(
                    icon: "road.lanes",
                    value: road == .oneWay ? "1-Way" : "2-Way",
                    label: "Road",
                    color: .cyan
                )
            }

            Spacer()

            // Stop button
            Button {
                showStopAlert = true
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .padding(14)
                    .background(Color.red.opacity(0.85))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 40)
    }
}

// MARK: - Supporting Views

struct ManeuverIcon: View {
    let maneuver: ManeuverType
    var body: some View {
        let (icon, color): (String, Color) = {
            switch maneuver {
            case .turnLeft:   return ("arrow.turn.up.left",  .blue)
            case .turnRight:  return ("arrow.turn.up.right", .blue)
            case .goStraight: return ("arrow.up",             .green)
            case .unknown:    return ("questionmark",          .gray)
            }
        }()
        Image(systemName: icon)
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(color)
            .padding(10)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
    }
}

struct StatBadge: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(value)
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
    }
}

// MARK: - ViewModel

final class CameraScreenViewModel: NSObject, ObservableObject {
    @Published var renderState = FrameRenderState()
    @Published var statusText = "Starting..."

    private var pipeline: NavigationPipeline?
    private let cameraManager = CameraManager()
    private var cancellables = Set<AnyCancellable>()

    var previewLayer: AVCaptureVideoPreviewLayer? { cameraManager.previewLayer }

    func start(destination: String,
               apiKey: String,
               keyframeInterval: Int,
               bikeLaneConf: Float,
               obstacleConf: Float,
               roadTypeConf: Float) {

        let pl = NavigationPipeline(
            apiKey: apiKey,
            keyframeInterval: keyframeInterval,
            bikeLaneConf: bikeLaneConf,
            obstacleConf: obstacleConf,
            roadTypeConf: roadTypeConf
        )
        self.pipeline = pl

        // Observe pipeline state
        pl.$renderState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.renderState = state }
            .store(in: &cancellables)

        pl.$navigationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.statusText = s }
            .store(in: &cancellables)

        // Setup camera
        cameraManager.requestPermissionAndSetup { [weak self] granted in
            guard let self, granted else {
                DispatchQueue.main.async { self?.statusText = "Camera permission denied" }
                return
            }
            self.cameraManager.delegate = self
            self.cameraManager.startSession()
            pl.updateCameraFOV(self.cameraManager.horizontalFOV)

            // Request location & start navigation
            pl.locationService.requestPermission()
            pl.locationService.startUpdating()

            // Start navigation route loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let loc = pl.locationService.currentLocation, !destination.isEmpty {
                    pl.startNavigation(destination: destination, currentLocation: loc)
                } else if destination.isEmpty {
                    pl.navigationStatus = "No destination — visual mode only"
                }
            }
        }
    }

    func stop() {
        cameraManager.stopSession()
        pipeline?.stopNavigation()
        cancellables.removeAll()
        pipeline = nil
    }
}

extension CameraScreenViewModel: CameraManagerDelegate {
    func cameraManager(_ manager: CameraManager, didOutput pixelBuffer: CVPixelBuffer, frameIndex: Int) {
        let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        pipeline?.processFrame(pixelBuffer, frameIndex: frameIndex, frameSize: frameSize)
    }
}
