# Third-party notices

CaptionBridge bundles the following third-party software in its app bundle.

## whisper.cpp (including ggml)

The bundled speech-recognition helper (`captionbridge-whisper-helper`, `whisper-cli`,
`libwhisper*.dylib`, `libggml*.dylib`) is built from
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) v1.7.6, which includes the
[ggml](https://github.com/ggml-org/ggml) tensor library. Both are distributed under
the MIT License:

```
MIT License

Copyright (c) 2023-2024 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Whisper models

The optional speech models downloaded in-app (`ggml-base.bin`, `ggml-small.bin`,
`ggml-medium-q5_0.bin`, `ggml-medium.bin`) are conversions of OpenAI's
[Whisper](https://github.com/openai/whisper) models, released by OpenAI under the
MIT License, hosted by the whisper.cpp project on Hugging Face.
