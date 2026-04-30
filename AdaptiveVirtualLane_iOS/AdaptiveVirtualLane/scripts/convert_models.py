#!/usr/bin/env python3
"""
Helper scripts for converting thesis models to CoreML format.
Run each section independently depending on which model you need to convert.

Requirements:
    pip install coremltools ultralytics torch torchvision
"""

# ============================================================
# 1. YOLO26n (Obstacle Detection — MS COCO pretrained)
# ============================================================
def export_yolo26n_obstacle():
    from ultralytics import YOLO
    model = YOLO("yolo26n.pt")          # downloads automatically if not present
    model.export(
        format="coreml",
        imgsz=640,
        nms=True,                       # bake NMS into the model
        int8=False,
        half=False,
    )
    print("✓ yolo26n.mlpackage exported — drag into Xcode")

# ============================================================
# 2. YOLO26n-Seg (Bike Lane — YOUR trained model)
#    Note: You already have bike_lane_seg.mlmodel from Ultralytics cloud.
#    If you need to re-export from a .pt checkpoint:
# ============================================================
def export_bike_lane_seg(checkpoint_path: str = "bike_lane_seg_best.pt"):
    from ultralytics import YOLO
    model = YOLO(checkpoint_path)
    model.export(
        format="coreml",
        imgsz=640,
        nms=True,
    )
    print("✓ bike_lane_seg.mlpackage exported")

# ============================================================
# 3. YOLO26n-cls (Road Type — YOUR trained model)
#    Same: you already have road_type_cls.mlmodel.
#    To re-export from .pt:
# ============================================================
def export_road_type_cls(checkpoint_path: str = "road_type_cls_best.pt"):
    from ultralytics import YOLO
    model = YOLO(checkpoint_path)
    model.export(format="coreml", imgsz=640)
    print("✓ road_type_cls.mlpackage exported")

# ============================================================
# 4. TwinLiteNet+ Medium (Drivable Area Segmentation)
# ============================================================
def export_twinlitenet_plus():
    """
    Clone: https://github.com/chequanghuy/TwinLiteNet
    Download weights from the repository's releases page.
    """
    import torch
    import coremltools as ct

    # Load the model (adjust import path to match the repo structure)
    try:
        from model.twinlitenet import TwinLiteNet  # adjust to actual class name
        model = TwinLiteNet()
        checkpoint = torch.load("TwinLiteNetPlus_Medium.pth", map_location="cpu")
        model.load_state_dict(checkpoint)
        model.eval()
    except ImportError:
        print("Clone TwinLiteNet repo and adjust the import path above.")
        return

    example_input = torch.randn(1, 3, 360, 640)  # adjust to model's expected input
    traced = torch.jit.trace(model, example_input)

    ml_model = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="input_image",
            shape=(1, 3, 360, 640),
            scale=1/255.0,
            bias=[0, 0, 0],
            color_layout=ct.colorlayout.RGB
        )],
        outputs=[ct.TensorType(name="drivable_mask")],
        minimum_deployment_target=ct.target.iOS17,
    )
    ml_model.save("TwinLiteNetPlusMedium.mlpackage")
    print("✓ TwinLiteNetPlusMedium.mlpackage exported")

# ============================================================
# 5. Depth Anything V2 Small
# ============================================================
def export_depth_anything_v2_small():
    """
    Option A: Use Apple's pre-converted model
    - Open Xcode → File → Add Package Dependencies
    - Or download from https://huggingface.co/apple/DepthAnythingV2-SmallCoreML

    Option B: Convert yourself from HuggingFace weights
    """
    import torch
    import coremltools as ct

    try:
        from depth_anything_v2.dpt import DepthAnythingV2
        model_configs = {
            'vits': {'encoder': 'vits', 'features': 64, 'out_channels': [48, 96, 192, 384]}
        }
        model = DepthAnythingV2(**model_configs['vits'])
        model.load_state_dict(torch.load("depth_anything_v2_vits.pth", map_location="cpu"))
        model.eval()
    except ImportError:
        print("pip install depth-anything-v2 or clone https://github.com/DepthAnything/Depth-Anything-V2")
        return

    example = torch.randn(1, 3, 518, 518)
    traced = torch.jit.trace(model, example)

    ml_model = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="input",
            shape=(1, 3, 518, 518),
            scale=1/255.0,
            color_layout=ct.colorlayout.RGB
        )],
        outputs=[ct.TensorType(name="depth")],
        compute_units=ct.ComputeUnit.ALL,          # enables Neural Engine
        minimum_deployment_target=ct.target.iOS17,
    )
    ml_model.save("DepthAnythingV2Small.mlpackage")
    print("✓ DepthAnythingV2Small.mlpackage exported")

# ============================================================
# Run all exports
# ============================================================
if __name__ == "__main__":
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"

    if cmd in ("obstacle", "all"):
        print("\n--- Exporting YOLO26n obstacle detector ---")
        export_yolo26n_obstacle()

    if cmd in ("depth", "all"):
        print("\n--- Exporting Depth Anything V2 Small ---")
        export_depth_anything_v2_small()

    if cmd in ("drivable", "all"):
        print("\n--- Exporting TwinLiteNet+ Medium ---")
        export_twinlitenet_plus()

    print("\nDone! Drag all .mlpackage files into your Xcode project.")
