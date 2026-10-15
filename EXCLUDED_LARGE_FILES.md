# Large unchanged files not included in this smaller archive

This archive contains the complete updated project **except** the large files and
folders below. None of them were modified by the mobile repair: they are
byte-identical to your existing SmartVision folder and to
github.com/soumyajali/SmartVision (commit 845b9dc).

The Flutter app does **not** need them to build (its model is
`assets/models/yolov8n.tflite`, which is included). The website/backend need the
`.pt` weights and the datasets.

## Restore
```bash
# from the folder that contains this file:
./restore_large_files.sh /path/to/your/original/SmartVision
# or, without an original copy:
git clone https://github.com/soumyajali/SmartVision /tmp/SmartVision-orig && ./restore_large_files.sh /tmp/SmartVision-orig
```

## Excluded (7311 files, 282 MB)

Folders (all contents): `datasets/`, `smart vision detection/`, `classification/`, `dummy_classification_dataset/`, `ai-chatbot/checkpoints/`, `detections/`, `recordings/`, `known_faces/`

Individual large files (SHA-256):

- `MobileNET_best.pth` (13.8 MB) `c20747d42a2bee1950b4e1ef0ca61bd9e360d844fc3cd295465bae61b02dc328`
- `MobileNET_best_dummy.pth` (8.8 MB) `ca86a11ba61c09d204d94d209bb91b5d72b609e5ea5d4a698af7c0ab0f1196c9`
- `SmartVision AI - Intelligent Multi-Class Object Recognition System.pdf` (1.3 MB) `030db69394f885dda3b491cca687fcbc04ad48327f3ea57f24a3b8685a1a41fa`
- `SmartVision_v3.pt` (49.6 MB) `5533a5d18c92871292f05fda6cd63345a75ffc647d5d4bd363631a067a2ad4a2`
- `ai-chatbot/checkpoints/qwen_chatbot_lora/tokenizer.json` (10.9 MB) `716ec13e363ec927a345aa1d39bb8ed88a0ce7fadcdef14509b1f2afd64a8bee`
- `app/assets/model.tflite` (12.2 MB) `51ce9fed4b20a13aed3315bc27911c9d9c7fbc126dfd8461e4a20be25357cdef`
- `weights/smartvision_best.pt` (6.2 MB) `48fced6793b27c363f90f1538041a1053b4d497b8f017af4d1eb50965e6e70ec`
- `yolov8m.pt` (49.7 MB) `5d4a90cdc7a21786cc59cd19778e9eafff836df9e2da32524737c7ee6efe4fe5`
- `yolov8n.pt` (6.2 MB) `f59b3d833e2ff32e194b5bb8e08d211dc7c5bdf144b90d2c8412c47ccfc83b36`
- `yolov8n.tflite` (12.2 MB) `51ce9fed4b20a13aed3315bc27911c9d9c7fbc126dfd8461e4a20be25357cdef`
- `yolov8s-world.pt` (25.9 MB) `095f5266bb9b654bd5ad9e21e9cdeda78e0f2c8460f5d652eaf04bab7ee251cf`

Other excluded files: `SmartVision_AI_Synopsis.pdf`
