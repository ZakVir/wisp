#!/usr/bin/env python3
"""Writes the model manifest (unsigned). Sign it with: wisp-bench sign-manifest <manifest.json>.
Every URL is pinned to a Hugging Face commit; sizes and SHA-256 were measured by downloading each file."""
import json, sys

MOON = "https://huggingface.co/moonshine-ai/moonshine-voice-assets/resolve/0bf2f2e5aff22e6fbba4300b00a4e00bbc4f8aae/model/small-streaming-en/quantized_26_08_21/"
moon_files = [
    ("adapter.ort", 2870368, "c665f742364febad597cc9ac1e0b341ffbee0e24a1466e2f3bde95e6e4771762"),
    ("cross_kv.ort", 5356536, "e2d3417144e9514055ebfefe8dcc4c0a55a55adcb8530435844c75c53e352bf6"),
    ("decoder_kv.ort", 81878600, "1a05465b1dd955858dfcbee039c0020fb5dd982b0f5094c34e61735d518d771b"),
    ("encoder.ort", 44148576, "2d4d973e91e8aca08c51e7e7efa28a46ab265b63d809d5294d18b86bcd85b993"),
    ("frontend.model.ort", 26944, "09b1210ae30dc5f0f3e45f0ebab914c254741323114f53fbbe5ae62cca35058f"),
    ("frontend.weights.ort", 7769464, "7ef97521bd4bad3928f5bb6808586f4fcc6e92bd5990394112eed7d4052ec338"),
    ("streaming_config.json", 512, "26f02b6afb22d60871a5efd85c3d38e569cc0ddb6c5eb6e93d3260152ae8a47a"),
    ("tokenizer.bin", 249974, "6884b35fd6377d4c4d32336a0bc152f36b64d1e45b6503683cdc238250a8472d"),
]
KOKO = "https://huggingface.co/aufklarer/Kokoro-82M-CoreML-INT8/resolve/4bc7df470ea4612a5b6539af16ebf301a027f491/"
koko_files = [
    ("G2PDecoder.mlmodelc/analytics/coremldata.bin", 243, "dbf1767747fdc188222d467a45b04608b396c76c71db3abb18a5fb3680ef9827"),
    ("G2PDecoder.mlmodelc/coremldata.bin", 545, "607e960f19b4d9a30317a5a11869fcce84b300a909fcab2cc756c0d98e2dacd9"),
    ("G2PDecoder.mlmodelc/metadata.json", 3064, "e54e98484fd60d26f22fd3c4e7fe87b0d92a5d2de1f958cc3c4bb36d4ae06a44"),
    ("G2PDecoder.mlmodelc/model.mil", 19737, "fe647c598e0d9454d360b8ee49a59ae57ca147fc5330863ba84ccb90dce482ad"),
    ("G2PDecoder.mlmodelc/weights/weight.bin", 828030, "cbaeb4e743359f607ab161af0c6d8a817462fdaec622ee788ef8ef952c5f8214"),
    ("G2PEncoder.mlmodelc/analytics/coremldata.bin", 243, "cf7fbd7e7a65529b2d2bf3941e458a0ab6dff7a298bf48e205a1727c81c26a99"),
    ("G2PEncoder.mlmodelc/coremldata.bin", 398, "0f14d46ca9fd06c68b4717294575b2b99449e67d40b7a2c56f926bf05cd90b11"),
    ("G2PEncoder.mlmodelc/metadata.json", 2034, "c8e0cfd7f494ac1b3662ff8f1914b2b45f79ffb2791724cdc0576981996732e1"),
    ("G2PEncoder.mlmodelc/model.mil", 20392, "8c617e569f37286b056dad800d862dc145be9a95fa9ed43857bb646ba199d7da"),
    ("G2PEncoder.mlmodelc/weights/weight.bin", 694592, "6926bcd2827d21fec82839487b987e06f85fd8a6a5bb896bc4f6062461d014ec"),
    ("g2p_vocab.json", 1665, "295ed64b86c2820cd665b0602ae50c6947c0e82ac643082873e0be87dca282ce"),
    ("us_gold.json", 3001196, "8507f89840f0813b10cf584740942f58e9cc9ad3660e24088b442ab0a6b126be"),
    ("us_silver.json", 3105352, "ea0e1abca0c9b18fb0d3402034633a337154a3153e9a9f49f97d668c908e140c"),
    ("vocab_index.json", 2034, "433690ab1da1256639c00179e7961a9e9f50ec91077a9c0877107c14e04fb989"),
]
ANE = "https://huggingface.co/FluidInference/kokoro-82m-coreml/resolve/006395f65025af251858b1ab0a7178a6a1e73f9f/ANE/"
# Kokoro as seven Core ML stages (laishere/kokoro-coreml conversion, FluidAudio's maintained build). Replaces the single
# INT8 model, whose vocoder added an audible grainy noise floor and whose timing ran ~25% fast.
ane_files = [
    ("KokoroAlbert.mlmodelc/analytics/coremldata.bin", 243, "14a61873d8759a38b79c93f9021ae865f408f56301209a0168dbfc2283265ccd"),
    ("KokoroAlbert.mlmodelc/coremldata.bin", 433, "70b6d2f8429229f6800dda9480341669f7ac0eabf05a82934d8632ab2b4b63a6"),
    ("KokoroAlbert.mlmodelc/metadata.json", 2480, "fe1d005481f646707a948267ac089dfb2cd2ccea7d5827a14c28587eb4c89930"),
    ("KokoroAlbert.mlmodelc/model.mil", 101485, "2038154d06a20e399a8ae35ec5c9242702cb23db8dd24dde7679cd53708e4eae"),
    ("KokoroAlbert.mlmodelc/weights/weight.bin", 5718848, "36089a39359b800d3e2c60e5e8ac9217d8f2d1010a8b9273192290e621f1fabc"),
    ("KokoroAlignment.mlmodelc/analytics/coremldata.bin", 243, "f6074d1039a9151d0f97dc6ec9ee0cd9c7b865f1af646d718ab38b659fa84f3f"),
    ("KokoroAlignment.mlmodelc/coremldata.bin", 484, "9a0fb4a536f665a052914d7f17b0e6ac80a3614f702e4be87ac0302c1143a4ea"),
    ("KokoroAlignment.mlmodelc/metadata.json", 3021, "6f610d23b9f93c7f1a968d6a861efa99725a191de696bf1c3be334ead39b7f00"),
    ("KokoroAlignment.mlmodelc/model.mil", 8194, "eb3a618bda0cdf95cdffab586ef5c76333d0d0a1dcb881190b3ef414f3421b3e"),
    ("KokoroAlignment.mlmodelc/weights/weight.bin", 4128, "2e7d69128b59d615fc3d3cf85637a687235fc086b1eb136359adb11a61615f6b"),
    ("KokoroNoise_v2.mlmodelc/analytics/coremldata.bin", 243, "53af6bf61482f6002bdb6e3a62f30774cde6e96411aebd888222a34b369f3d04"),
    ("KokoroNoise_v2.mlmodelc/coremldata.bin", 440, "9911047f924b41f8b92811c32c50b7c718bd7b0c14842b3bc1b66b9ffe341a19"),
    ("KokoroNoise_v2.mlmodelc/metadata.json", 3020, "eb3102217532d952479c6f1b04d26d7ac4cdbc59875b6a23e8aae86e5e02c2bc"),
    ("KokoroNoise_v2.mlmodelc/model.mil", 93152, "60233949d896f15ef38aea19afda558935d7569fa77a3ca4babddd3ffe845a36"),
    ("KokoroNoise_v2.mlmodelc/weights/weight.bin", 4580160, "1102fc2d31dfcfe3de3978a4c78b65202ff8b0a4d55a9304213bd4e8bda66bc2"),
    ("KokoroPostAlbert.mlmodelc/analytics/coremldata.bin", 243, "6640044c875505382edbc361cdd56f3f1c30f082953e0f9473a31ae3f71e6c43"),
    ("KokoroPostAlbert.mlmodelc/coremldata.bin", 556, "86de3ab0c1e8c6f8842b57bc24695a5099590c49b864e3fa2737b1fb5b15ba3b"),
    ("KokoroPostAlbert.mlmodelc/metadata.json", 4171, "2e3be1af412a76e340120a01cd04a502666371ada86b1fdaf5a622896e0bf979"),
    ("KokoroPostAlbert.mlmodelc/model.mil", 60047, "450b73a3b179e1702e7b2210bad008eac20d58b2d6076e3c2de76290a66e5fef"),
    ("KokoroPostAlbert.mlmodelc/weights/weight.bin", 13806464, "e4f300a23cc2e05d38680d9fc94681cc722d445076d1d248f83255122ba091c8"),
    ("KokoroProsody_v2.mlmodelc/analytics/coremldata.bin", 243, "804d7d2e9a8fed345cedb57da61bd27fdd95db22a070cfa7d42ccd4f8e80a443"),
    ("KokoroProsody_v2.mlmodelc/coremldata.bin", 421, "db8776a4896f690fd254cdb68a4551c168411c9b3fb98219630215bc3c357986"),
    ("KokoroProsody_v2.mlmodelc/model.mil", 73353, "e6acad9f44d70b1dba0aea6a5d25ee4edf68fe8f2933399ee81f70ace61cbc8b"),
    ("KokoroProsody_v2.mlmodelc/weights/weight.bin", 8513664, "70eea4cd2523992fa1fea840e31ab6f4fdd69c1598e220985a2ae6ea5da1e944"),
    ("KokoroTail_v2.mlmodelc/analytics/coremldata.bin", 243, "a06e4b91c2b8a8be3ff701558a5f1f6484921f948202663fe6df78f248d42222"),
    ("KokoroTail_v2.mlmodelc/coremldata.bin", 392, "527271f6df56cc308a5f89374c92108aef7b837ab15f0ba4900d555588dbd905"),
    ("KokoroTail_v2.mlmodelc/metadata.json", 1872, "7708ecc145eecf8e3ef5ef8979ea7a4f77d04c8da787454c6d9190e5300fc50b"),
    ("KokoroTail_v2.mlmodelc/model.mil", 7014, "b0b8fd573bac76ba7eb85730eeb25538fc7f1c666ecbf939fd4b3a4ad4495ad7"),
    ("KokoroTail_v2.mlmodelc/weights/weight.bin", 81088, "8ede31ec20df7d86a124287ac12d13507651e2a693e9d4f35f0e7f92cba422c7"),
    ("KokoroVocoder.mlmodelc/analytics/coremldata.bin", 243, "1cc4f1e6436597c6d458a845570d9d0ace458813ff90f225d08e0e713496b463"),
    ("KokoroVocoder.mlmodelc/coremldata.bin", 626, "71bac80d2f2f077fefc0d66cdc39c0faaa96540b3a6149093ef29de01b1f8764"),
    ("KokoroVocoder.mlmodelc/metadata.json", 4331, "a8e768f151225a52476d35f6ab90805ae00f1f78b83be4ca21327029c800c183"),
    ("KokoroVocoder.mlmodelc/model.mil", 309000, "52f2febec45094e78a5948a3a47f023be8fc57cfd48cc99e8d4c358a13674ef2"),
    ("KokoroVocoder.mlmodelc/weights/weight.bin", 48889920, "6d1f96eb50218ab687b12d6d862d2ae854c12b7165c3cd9b6b5cef261ef02ff1"),
]
VOICE = ("voices/af_heart.bin", 522240, "d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b",
         "https://huggingface.co/FluidInference/kokoro-82m-coreml/resolve/006395f65025af251858b1ab0a7178a6a1e73f9f/ANE/af_heart.bin")

FLUID = "https://huggingface.co/FluidInference/kokoro-82m-coreml/resolve/006395f65025af251858b1ab0a7178a6a1e73f9f/voices/"
# Extra Kokoro v1.0 voices (full 510x256 style packs as JSON), chosen from hexgrad's best-graded English voices.
voice_files = [
    ("af_bella", 2678538, "e7bdbe207b927d1e59556dcda69b976cbbdc87be5e4affeea5bf030fca80e55c"),
    ("af_nicole", 2680162, "a52212b76eeabff2e7723439649ef55e244d0a16477816dfb84c3f0e632d4323"),
    ("af_sarah", 2672574, "3c5270deda46faf0130837100a51ccbe39f5c268886f59e31aca52687b876ecf"),
    ("af_nova", 2677525, "54d03024723e2f6c0cf01b2e685712155d24ffaa5275443367f5725416ec7c4d"),
    ("bf_emma", 2679667, "2b7f73a1af7bd195d1c4bae834cc96d4e319e26abb4ddbe4c7c43485789dda69"),
    ("bf_isabella", 2675405, "63a73d3256cb932492c4d3a3175860b774b149c814aeee480365baf3d46ad3a9"),
    ("am_michael", 2667552, "ec6e03f1fc30c11020ade45f587a64e1b8c51c08e8ab6f59bdf089f410c2b924"),
    ("am_fenrir", 2678091, "7c983af1d3317de8a821ea46ab3cb8f1839624f91adb66bb5f24043a777078ba"),
    ("am_puck", 2671969, "3f603430c6050de2b00626aa9509fdfcd5a119b33dee88a05d7174897bf12694"),
    ("bm_george", 2669308, "842150816a3503bdb97f9e0e96dd6dbbafc27eec5bb78957da48875cde398f10"),
    ("bm_fable", 2656216, "757ddc02be15dc73f939a4c4f7d2642d3bd99d925c9360eac8533c356cf9f5bc"),
]

manifest = {
    "schema": 1,
    "manifestVersion": "2026.10.02.1",
    "models": [
        {
            "id": "moonshine-small-streaming-en", "version": "quantized_26_08_21", "kind": "speechToText",
            "displayName": "Moonshine v2 Small (English, streaming)", "runtime": "moonshine-ort",
            "license": "MIT", "licenseURL": "https://github.com/moonshine-ai/moonshine/blob/main/LICENSE", "minMacOS": "15.0",
            "files": [{"path": p, "url": MOON + p, "size": s, "sha256": h} for p, s, h in moon_files],
        },
        {
            "id": "kokoro-82m-en", "version": "v1.0-chain-006395f", "kind": "textToSpeech",
            "displayName": "Kokoro 82M v1.0 (English)", "runtime": "kokoro-coreml",
            "license": "Apache-2.0", "licenseURL": "https://huggingface.co/hexgrad/Kokoro-82M", "minMacOS": "15.0",
            "files": [{"path": p, "url": KOKO + p, "size": s, "sha256": h} for p, s, h in koko_files]
                     + [{"path": p, "url": ANE + p, "size": s, "sha256": h} for p, s, h in ane_files]
                     + [{"path": VOICE[0], "url": VOICE[3], "size": VOICE[1], "sha256": VOICE[2]}],
        },
        {
            "id": "kokoro-voices-en", "version": "v1.0-006395f", "kind": "textToSpeech",
            "displayName": "Kokoro extra voices (English)", "runtime": "kokoro-voices",
            "license": "Apache-2.0", "licenseURL": "https://huggingface.co/hexgrad/Kokoro-82M", "minMacOS": "15.0",
            "files": [{"path": f"voices/{v}.json", "url": f"{FLUID}{v}.json", "size": n, "sha256": h} for v, n, h in voice_files],
        },
    ],
}
out = sys.argv[1] if len(sys.argv) > 1 else "manifest.json"
with open(out, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
total = sum(x["size"] for m in manifest["models"] for x in m["files"])
print(f"wrote {out}: {len(manifest['models'])} models, {total} bytes ({total/1048576:.1f} MiB)")
