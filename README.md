# Adaptive Virtual Lane Generation — iOS App

> **Bachelor Thesis Implementation**  
> Samuel Atef Samwaiel Elkalamony Youssef  
> Media Engineering and Technology Faculty, German University in Cairo  
> Supervisors: Dr. Milad Ghantous · Dr. Hassan Soubra

---

## Overview

This iOS application implements the complete **Adaptive Virtual Lane Generation** system described in the thesis. It takes a live rear-camera video stream from a smartphone mounted on a bicycle handlebar and overlays a real-time, physically-grounded virtual bike lane onto the screen.

### System Architecture

```
Camera Feed (720p)
      │
      ▼
Preprocessing ── Resize 640×640 · Normalize · Color Correction (CLAHE)
      │
      ├──────────────────────────────────────┐
      ▼ (every 5th frame = keyframe)         ▼ (non-keyframes)
┌─────────────────────────┐         DeepSORT Tracking
│  Parallel:              │         Optical Flow Warp
│  BikeLane Seg + YOLO26n │         Proximity Check
│  Obstacle Det + YOLO26n │         Path Render
└────────┬────────────────┘
         │
   Bike Lane?
    YES ─────────────────────────► Path within Bike Lane Mask
    NO
         │
         ▼
   Drivable Area Seg (TwinLiteNet+ Medium)
         │
   Monocular Depth Est (DA2-S)
         │
   Road Type Classification (YOLO26n-cls)
         │
   GPS + TomTom Traffic API (async, 60s cache)
         │
   Adaptive Width Decision Table
   ┌──────────────┬────────────┬───────────┐
   │ Road Type    │ Traffic    │ Width     │
   ├──────────────┼────────────┼───────────┤
   │ One-Way      │ Low        │ 1.8 m     │
   │ One-Way      │ Med/High   │ 1.6 m     │
   │ Two-Way      │ Low        │ 1.4 m     │
   │ Two-Way      │ Med/High   │ 1.2 m     │
   └──────────────┴────────────┴───────────┘
         │
   Path Generation
   ├─ 4 scan-line right anchors
   ├─ Depth-aware pixel width projection
   ├─ Obstacle avoidance (0.5m clearance)
   └─ Cubic Bézier curves + Kalman filter
         │
   Temporal Consistency
   ├─ Majority voting (categorical)
   ├─ One-Euro filter (continuous)
   └─ Kalman filter (path points)
         │
   Render Overlay → iPhone Screen
```

---

## Requirements

- **Xcode 15** or later
- **iOS 17** deployment target
- iPhone with A12 Bionic or newer (Neural Engine for CoreML)
- A **TomTom API key** (free tier at [developer.tomtom.com](https://developer.tomtom.com))

---

## Project Setup (Step-by-Step)

### 1. Clone / Open the Project

```bash
open AdaptiveVirtualLane.xcodeproj
```

Or create a new Xcode project:
1. File → New → Project → App
2. Product Name: `AdaptiveVirtualLane`
3. Interface: SwiftUI · Language: Swift · Minimum Deployment: iOS 17
4. Copy all `.swift` files from this repository into the project

### 2. Add Your CoreML Models

You have two models from training. Add them to Xcode:

1. Drag both files into the Xcode project navigator under `AdaptiveVirtualLane/`
2. Make sure **"Add to target: AdaptiveVirtualLane"** is checked
3. Xcode will auto-compile `.mlmodel` → `.mlmodelc`

| File | Purpose | Used in |
|------|---------|---------|
| `bike_lane_seg.mlmodel` | YOLO26n-Seg bike lane segmentation | `BikeLaneDetector.swift` |
| `road_type_cls.mlmodel` | YOLO26n-cls one-way vs two-way | `RoadTypeClassifier.swift` |

### 3. Add Additional Models

You need to obtain / convert these models to CoreML format:

#### a) TwinLiteNet+ Medium (Drivable Area Segmentation)
```bash
pip install coremltools ultralytics
# Download TwinLiteNet+ from https://github.com/chequanghuy/TwinLiteNet
# Convert with:
python3 -c "
import coremltools as ct
import torch
# Load your PyTorch model
model = ...  # load TwinLiteNet+ Medium
traced = torch.jit.trace(model, torch.randn(1,3,640,640))
ml = ct.convert(traced, inputs=[ct.ImageType(name='input', shape=(1,3,640,640))])
ml.save('TwinLiteNetPlusMedium.mlpackage')
"
```
Then drag `TwinLiteNetPlusMedium.mlpackage` into Xcode.

#### b) Depth Anything V2 Small (Depth Estimation)
Apple has natively integrated DA2-S into Core ML:
```bash
# Option 1: Use Apple's model from the ML Models gallery in Xcode
# File → Add Package Dependencies → search "DepthAnything"

# Option 2: Convert yourself
pip install depth-anything-v2
python3 convert_da2_to_coreml.py  # see scripts/convert_depth.py
```

#### c) YOLO26n (Obstacle Detection on MS COCO)
```bash
pip install ultralytics
python3 -c "
from ultralytics import YOLO
model = YOLO('yolo26n.pt')
model.export(format='coreml', imgsz=640, nms=True)
"
# Drag the generated yolo26n.mlpackage into Xcode
```

### 4. Set Your TomTom API Key

**Option A — In-App Settings (recommended):**
1. Launch the app → tap the ⚙️ gear icon on the Home screen
2. Enter your API key in the "TomTom API Key" field
3. Tap Save

**Option B — Hardcode for development:**
In `AppState.swift`, change:
```swift
@Published var tomTomAPIKey: String = "YOUR_TOMTOM_API_KEY_HERE"
```

Get a free TomTom API key at: https://developer.tomtom.com/  
The free tier provides **2,500 non-tile API requests/day** — sufficient for testing.

### 5. Configure Signing

1. Select the `AdaptiveVirtualLane` target
2. Signing & Capabilities → Team: select your Apple developer team
3. Bundle Identifier: change to something unique, e.g. `com.yourname.adaptivevirtuallane`

### 6. Build & Run

1. Connect your iPhone via USB
2. Select your device in the Xcode toolbar
3. Press ▶ Run (Cmd+R)
4. **Trust the developer certificate** on your iPhone: Settings → General → VPN & Device Management

---

## Usage

1. **Mount your iPhone** on the bicycle handlebar in a forward-facing, portrait orientation
2. Launch the app
3. Enter your destination address (or leave blank for visual-only mode)
4. Tap **Start Navigation**
5. The app will:
   - Request camera and location permissions
   - Load a bicycle-appropriate route via TomTom
   - Begin generating the virtual lane overlay in real time

### Screen Layout

```
┌─────────────────────┐
│ ← [Back]  [Status]  │  ← Top bar
│                     │
│   LIVE CAMERA FEED  │
│                     │
│ ┌─ Virtual Lane ─┐  │
│ │  (green fill)  │  │  ← Bézier curve overlay
│ │  ─ ─ ─ ─ ─ ─  │  │
│ └────────────────┘  │
│ [Obstacle boxes]    │
│ [⚠️ Warnings]       │
│                     │
│ [Lane] [Traffic] ●  │  ← Bottom HUD
└─────────────────────┘
```

### Voice Guidance

The app uses the device speaker (or paired Bluetooth earpiece) for turn-by-turn guidance:
- **20 metres before intersection:** "Turn right ahead" / "Turn left ahead" / "Continue straight ahead"
- **At intersection:** "Turn right now" / "Turn left now" / "Go straight"
- **Hazard alerts:** "Warning: narrow road ahead" / "Obstacle detected ahead"

---

## File Structure

```
AdaptiveVirtualLane/
├── App/
│   ├── AdaptiveVirtualLaneApp.swift    # App entry point
│   └── AppState.swift                  # Global state
├── Models/
│   └── CoreModels.swift                # Data types & Bézier math
├── Modules/
│   ├── CameraManager.swift             # AVFoundation capture
│   ├── FramePreprocessor.swift         # Resize + color correction
│   ├── BikeLaneDetector.swift          # YOLO26n-Seg inference
│   ├── ObstacleDetector.swift          # YOLO26n + DeepSORT tracker
│   ├── DrivableAreaSegmentor.swift     # TwinLiteNet+ inference
│   ├── DepthEstimator.swift            # DA2-S + pinhole projection
│   ├── RoadTypeClassifier.swift        # YOLO26n-cls inference
│   ├── PathGenerator.swift             # Bézier path construction
│   ├── OpticalFlowWarper.swift         # Non-keyframe propagation
│   ├── TemporalBuffer.swift            # Kalman + One-Euro + majority vote
│   └── NavigationPipeline.swift        # Central coordinator
├── Services/
│   ├── TomTomService.swift             # Geocoding, routing, traffic
│   ├── LocationService.swift           # CoreLocation GPS
│   └── VoiceGuidanceService.swift      # AVSpeechSynthesizer
├── UI/
│   ├── Screens/
│   │   ├── ContentView.swift           # Root navigation
│   │   ├── HomeScreen.swift            # Destination input
│   │   ├── CameraScreen.swift          # Main AR view + HUD
│   │   └── SettingsScreen.swift        # Configuration
│   └── Components/
│       ├── PathOverlayRenderer.swift   # CGContext drawing engine
│       ├── CameraPreviewView.swift     # UIView with overlay layer
│       └── CameraPreviewRepresentable.swift  # SwiftUI bridge
└── Resources/
    └── Info.plist                      # Permissions & config
```

---

## Third-Party Dependencies

**None required.** The app uses only Apple system frameworks:

| Framework | Usage |
|-----------|-------|
| `CoreML` | Model inference for all 5 neural networks |
| `Vision` | VNCoreMLRequest, optical flow tracking |
| `AVFoundation` | Camera capture, speech synthesis |
| `CoreLocation` | GPS positioning |
| `CoreImage` | Frame preprocessing, color correction |
| `SwiftUI` | All UI screens |
| `Accelerate` | Fast array operations |

---

## Performance Notes

- **Keyframe interval = 5** (default): processes heavy perception every 5 frames
- **Non-keyframes**: only DeepSORT tracking + optical flow warp (< 5ms)
- **Bike lane branch saves ~4.63 GFLOPs** per keyframe when a lane is detected
- **Traffic API cached for 60 seconds** — no frame-rate impact
- **DA2-S** runs on the Neural Engine — significantly faster than CPU

### Expected FPS (iPhone 15 Pro, estimated)
| Mode | FPS |
|------|-----|
| Bike lane detected (fast branch) | ~25–30 fps |
| Open road with depth + road type | ~15–20 fps |
| Non-keyframe (tracking only) | ~60 fps |

---

## Troubleshooting

**"bike_lane_seg model not found"**  
→ Make sure `bike_lane_seg.mlmodel` is added to the Xcode target and the filename matches exactly.

**"Camera permission denied"**  
→ Go to iPhone Settings → Privacy → Camera → enable for AdaptiveVirtualLane.

**No route loads**  
→ Check that your TomTom API key is entered in Settings and has remaining quota.

**Lane looks jittery**  
→ Increase the keyframe interval slightly (Settings → Keyframe Interval) to give the One-Euro filter more smoothing time.

**App crashes on model load**  
→ The model was not compiled for the iOS platform. Re-export from Ultralytics with `format='coreml'` and iOS as the target.

---

## Citation

```
Youssef, S.A.S.E. (2025). Adaptive Virtual Lane Generation. 
Bachelor Thesis, German University in Cairo. 
Supervisors: Dr. M. Ghantous, Dr. H. Soubra.
```
