# Third-Party Notices

Boltty is licensed under GPL-3.0-or-later (`LICENSE`). What it ships from others is below, with
each licence as its authors wrote it. This file and `LICENSE` are copied into
`Boltty.app/Contents/Resources/`, so every copy of the app carries them.

## Sounds

Boltty's interface sounds are its own: synthesized from sine waves by
`apps/macos/scripts/render-sounds.py` and covered by Boltty's licence.

## FluidAudio (ported code)

Boltty runs the Supertonic-3 voice with its own Core ML code. Parts of it
(`apps/macos/Sources/Boltty/Services/LocalVoice/Supertonic/`) are ported from
FluidAudio by FluidInference, which is licensed under the Apache License, Version 2.0, and say so
in their headers.

> Licensed under the Apache License, Version 2.0 (the "License"); you may not
> use this file except in compliance with the License. You may obtain a copy of
> the License at https://www.apache.org/licenses/LICENSE-2.0
>
> Unless required by applicable law or agreed to in writing, software
> distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
> WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
> License for the specific language governing permissions and limitations under
> the License.

Source: https://github.com/FluidInference/FluidAudio

## Models downloaded on request

These are not in the app. Boltty downloads one only when the person asks for it
in Settings, from the pinned revision named in `LocalVoiceCatalog.swift`, and
keeps it in `~/Library/Application Support/Boltty/Models`.

- **Supertonic-3** by Supertone Inc., as converted to Core ML by FluidInference
  (`FluidInference/supertonic-3-coreml` on Hugging Face). BigScience OpenRAIL-M;
  its `LICENSE`, with the use restrictions it carries, is downloaded with it.
- **Parakeet TDT 0.6B v3** by NVIDIA, as converted to Core ML by FluidInference.
  CC BY 4.0.
