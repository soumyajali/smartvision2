# Meet the Builders — profile configuration

One file drives both the website (`ui/builders.py`) and the Flutter app
(`lib/screens/builders/builders_screen.dart`): `assets/builders/builders.json`.

Each profile has exactly these fields (there is intentionally **no role / job
title field**):

| Field | Meaning |
|---|---|
| `photo` | File name inside `assets/builders/photos/` (e.g. `asha.jpg`). Square photos look best; they are cropped to a circle. |
| `name` | Full name as provided by the builder. |
| `mobile` | Mobile number as provided. |
| `show_mobile` | `true` only when the builder has approved publishing the number. When `false` the number is never shown. |
| `about` | Short biography / description provided by the builder. |
| `placeholder` | Keep `true` until real details are supplied. Placeholder cards are clearly labelled "Profile pending" and never show invented details. |

To add a builder: copy one object in `builders`, give it a unique `id`, fill the
fields, set `placeholder` to `false`, and put the photo in `photos/`. Remove
unused placeholder entries. For the Flutter app, rebuild the APK after editing
(photos in `assets/builders/photos/` are bundled automatically).
