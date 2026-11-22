#!/usr/bin/env python3
"""Isolated automated tests for MotionDesk Build 38.

Uses ONLY temporary directories and mocked HTTP transports.
Never reads or mutates real ~/Library/Application Support/MotionDesk registries,
never touches real model weights, never makes paid API requests.
"""

from __future__ import annotations

import base64
import json
import os
import struct
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

STUDIO = Path(__file__).resolve().parent.parent
RESOURCES = STUDIO / "resources"
SRC = STUDIO / "src"

sys.path.insert(0, str(RESOURCES))
import comfy_workflows
import online_image
import worker

# Minimal valid 1x1 transparent PNG bytes
TINY_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
)


def write_synthetic_safetensors(path: Path, *, include_lora_pair: bool = False, tag: int = 1) -> None:
    """Create a tiny structurally valid .safetensors file for isolated tests."""
    payload = bytearray()
    header: dict[str, object] = {"__metadata__": {"format": "pt", "test_tag": str(tag)}}

    def add_tensor(name: str, values: list[float]) -> None:
        start = len(payload)
        for v in values:
            payload.extend(struct.pack("<f", v))
        end = len(payload)
        header[name] = {"dtype": "F32", "shape": [len(values)], "data_offsets": [start, end]}

    if include_lora_pair:
        add_tensor("model.block0.lora_A.weight", [float(tag), 0.5, -0.25, 1.0])
        add_tensor("model.block0.lora_B.weight", [0.25, -0.5, float(tag), 0.75])
    else:
        add_tensor("model.diffusion_model.weight", [float(tag), 0.25, 0.5, 0.75])

    header_bytes = json.dumps(header).encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(struct.pack("<Q", len(header_bytes)) + header_bytes + bytes(payload))


def test_python_user_models_all_six_architectures() -> None:
    expected_categories = {
        "zimage": ("diffusion_models", "UNETLoader", "unet_name"),
        "redcraft": ("checkpoints", "CheckpointLoaderSimple", "ckpt_name"),
        "iniverse_flux": ("checkpoints", "CheckpointLoaderSimple", "ckpt_name"),
        "moss": ("diffusion_models", "UNETLoader", "unet_name"),
        "krea2": ("diffusion_models", "UNETLoader", "unet_name"),
        "sdxl1": ("checkpoints", "CheckpointLoaderSimple", "ckpt_name"),
    }

    with tempfile.TemporaryDirectory(prefix="md-b38-py-models-") as td:
        root = Path(td)
        models_reg = root / "user_models.json"
        loras_reg = root / "user_loras.json"

        entries = []
        for idx, (base, (cat, _, _)) in enumerate(expected_categories.items()):
            entries.append({
                "id": f"umodel_{base}_{idx}",
                "displayName": f"Custom {base}",
                "baseProfile": base,
                "primaryCategory": cat,
                "primaryWeight": f"custom_{base}_weight.safetensors",
                "secondaryWeights": {},
                "notes": "synthetic test",
                "isBuiltInOverride": False,
            })

        models_reg.write_text(json.dumps({"schemaVersion": 1, "entries": entries, "hiddenBuiltInIds": []}), encoding="utf-8")
        # Also bind one user LoRA directly to umodel_sdxl1_5 and one to base krea2
        loras_reg.write_text(json.dumps([
            {
                "id": "user_custom_sdxl_lora",
                "displayName": "Custom SDXL LoRA",
                "filename": "MotionDesk/" + ("a" * 64) + ".safetensors",
                "compatibleModels": ["umodel_sdxl1_5"],
                "defaultStrength": 0.85,
                "triggerNote": "test",
            },
            {
                "id": "user_base_krea2_lora",
                "displayName": "Base Krea2 LoRA",
                "filename": "MotionDesk/" + ("b" * 64) + ".safetensors",
                "compatibleModels": ["krea2"],
                "defaultStrength": 0.9,
                "triggerNote": "test",
            },
        ]), encoding="utf-8")

        old_m = os.environ.get("MOTIONDESK_USER_MODELS_REGISTRY")
        old_l = os.environ.get("MOTIONDESK_LORA_REGISTRY")
        os.environ["MOTIONDESK_USER_MODELS_REGISTRY"] = str(models_reg)
        os.environ["MOTIONDESK_LORA_REGISTRY"] = str(loras_reg)
        try:
            profiles = comfy_workflows.load_profiles(RESOURCES)
            for idx, (base, (cat, loader_type, input_key)) in enumerate(expected_categories.items()):
                uid = f"umodel_{base}_{idx}"
                assert uid in profiles["models"], f"Missing custom model {uid}"
                req_models = comfy_workflows.required_models_for_preset(uid, "", RESOURCES)
                assert req_models.get(cat) == [f"custom_{base}_weight.safetensors"], (
                    f"{uid}: expected {cat} to have ONLY custom weight, got {req_models}"
                )
                other_cat = "diffusion_models" if cat == "checkpoints" else "checkpoints"
                assert other_cat not in req_models, f"{uid}: leftover primary category {other_cat} in {req_models}"

                graph, meta = comfy_workflows.resolve_builtin_graph(
                    uid, {"kind": "image", "prompt": "coastal lighthouse", "aspect": "1:1", "seed": 42}, RESOURCES
                )
                loader_nodes = [n for n in graph.values() if n.get("class_type") == loader_type]
                assert loader_nodes, f"{uid}: missing {loader_type}"
                assert all(n["inputs"][input_key] == f"custom_{base}_weight.safetensors" for n in loader_nodes)
                canvas = comfy_workflows.api_graph_to_canvas_workflow(graph)
                diffs = comfy_workflows.verify_canvas_roundtrip(graph, canvas)
                assert diffs == [], f"{uid}: canvas roundtrip diffs: {diffs}"

            # Custom model + direct LoRA binding AND inherited baseProfile LoRA binding
            sdxl_req = comfy_workflows.required_models_for_preset("umodel_sdxl1_5", "user_custom_sdxl_lora", RESOURCES)
            assert sdxl_req["loras"] == ["MotionDesk/" + ("a" * 64) + ".safetensors"]
            krea_req = comfy_workflows.required_models_for_preset("umodel_krea2_4", "user_base_krea2_lora", RESOURCES)
            assert krea_req["loras"] == ["MotionDesk/" + ("b" * 64) + ".safetensors"]
            # Incompatible LoRA still rejected
            try:
                comfy_workflows.required_models_for_preset("umodel_sdxl1_5", "user_base_krea2_lora", RESOURCES)
                raise AssertionError("Expected incompatible LoRA rejection")
            except ValueError:
                pass

            # Mismatched primaryCategory must be rejected for both checkpoints and diffusion_models bases
            for bad_base, bad_cat in [("redcraft", "diffusion_models"), ("iniverse_flux", "diffusion_models"), ("zimage", "checkpoints")]:
                models_reg.write_text(json.dumps({
                    "schemaVersion": 1,
                    "entries": [{
                        "id": f"umodel_bad_{bad_base}",
                        "displayName": "Bad Cat",
                        "baseProfile": bad_base,
                        "primaryCategory": bad_cat,
                        "primaryWeight": "bad.safetensors",
                    }],
                    "hiddenBuiltInIds": [],
                }), encoding="utf-8")
                try:
                    comfy_workflows.load_profiles(RESOURCES)
                    raise AssertionError(f"Expected primaryCategory mismatch error for {bad_base}/{bad_cat}")
                except ValueError as exc:
                    assert "載入器類別" in str(exc)
        finally:
            if old_m is None:
                os.environ.pop("MOTIONDESK_USER_MODELS_REGISTRY", None)
            else:
                os.environ["MOTIONDESK_USER_MODELS_REGISTRY"] = old_m
            if old_l is None:
                os.environ.pop("MOTIONDESK_LORA_REGISTRY", None)
            else:
                os.environ["MOTIONDESK_LORA_REGISTRY"] = old_l
    print("  [PASS] Python user_models: all 6 architectures, loader category guard, no leftover primary weight, LoRA routing & Canvas roundtrip")


def test_online_image_mocked_http_and_redaction() -> None:
    with tempfile.TemporaryDirectory(prefix="md-b38-online-") as td:
        out_dir = Path(td) / "out"
        test_openai_key = "sk-test-secret-echo-99999"
        test_gemini_key = "AIza-test-secret-echo-88888"

        # 1. OpenAI success mock
        captured: dict[str, object] = {}

        def mock_openai_ok(url: str, headers: dict[str, str], body: bytes, timeout: float):
            captured["url"] = url
            captured["headers"] = headers
            captured["body"] = json.loads(body.decode("utf-8"))
            return 200, json.dumps({"data": [{"b64_json": base64.b64encode(TINY_PNG).decode("ascii")}]}).encode("utf-8")

        res = online_image.generate_openai_image(
            prompt="sunlit harbor",
            api_key=test_openai_key,
            output_dir=out_dir,
            aspect="16:9",
            quality="low",
            transport=mock_openai_ok,
        )
        assert captured["url"] == "https://api.openai.com/v1/images/generations"
        assert captured["headers"]["Authorization"] == f"Bearer {test_openai_key}"
        assert captured["body"]["model"] == "gpt-image-2.5-flare"
        assert captured["body"]["size"] == "1536x1024"
        assert Path(res["paths"][0]).read_bytes() == TINY_PNG

        # 2. Gemini Interactions API success mock (ignores non-model_output steps)
        def mock_gemini_ok(url: str, headers: dict[str, str], body: bytes, timeout: float):
            captured["g_url"] = url
            captured["g_headers"] = headers
            captured["g_body"] = json.loads(body.decode("utf-8"))
            payload = {
                "status": "completed",
                "steps": [
                    {"type": "tool_output", "content": [{"type": "image", "data": "not_used", "mime_type": "image/png"}]},
                    {
                        "type": "model_output",
                        "content": [
                            {"type": "text", "text": "done"},
                            {"type": "image", "data": base64.b64encode(TINY_PNG).decode("ascii"), "mime_type": "image/png"},
                        ],
                    },
                ],
            }
            return 200, json.dumps(payload).encode("utf-8")

        gres = online_image.generate_gemini_image(
            prompt="navy lighthouse",
            api_key=test_gemini_key,
            output_dir=out_dir,
            aspect="16:9",
            image_size="1K",
            transport=mock_gemini_ok,
        )
        assert captured["g_url"] == "https://generativelanguage.googleapis.com/v1beta/interactions"
        assert captured["g_headers"]["x-goog-api-key"] == test_gemini_key
        assert captured["g_headers"]["Api-Revision"] == "2026-05-20"
        assert captured["g_body"]["model"] == "gemini-nano-banana-2.1"
        assert captured["g_body"]["response_format"] == {"type": "image", "aspect_ratio": "16:9", "image_size": "1K"}
        assert Path(gres["paths"][0]).read_bytes() == TINY_PNG

        # 3. Gemini blocked / missing model_output rejected
        def mock_gemini_blocked(url: str, headers: dict[str, str], body: bytes, timeout: float):
            return 200, json.dumps({"status": "blocked", "steps": []}).encode("utf-8")

        try:
            online_image.generate_gemini_image(prompt="test", api_key=test_gemini_key, output_dir=out_dir, transport=mock_gemini_blocked)
            raise AssertionError("Expected blocked Gemini response to fail")
        except RuntimeError as exc:
            assert "blocked" in str(exc)

        # 4. Secret redaction when upstream HTTP error echoes full API key
        def mock_openai_echo_key(url: str, headers: dict[str, str], body: bytes, timeout: float):
            return 401, json.dumps({"error": {"message": f"Invalid key provided: {test_openai_key}"}}).encode("utf-8")

        try:
            online_image.generate_openai_image(prompt="test", api_key=test_openai_key, output_dir=out_dir, transport=mock_openai_echo_key)
            raise AssertionError("Expected 401 error")
        except RuntimeError as exc:
            msg = str(exc)
            assert test_openai_key not in msg, f"API key leaked into exception: {msg}"
            assert "[REDACTED]" in msg

        def mock_gemini_echo_key(url: str, headers: dict[str, str], body: bytes, timeout: float):
            return 403, json.dumps({"error": {"message": f"Denied for key {test_gemini_key}"}}).encode("utf-8")

        try:
            online_image.generate_gemini_image(prompt="test", api_key=test_gemini_key, output_dir=out_dir, transport=mock_gemini_echo_key)
            raise AssertionError("Expected 403 error")
        except RuntimeError as exc:
            msg = str(exc)
            assert test_gemini_key not in msg, f"Gemini API key leaked into exception: {msg}"
            assert "[REDACTED]" in msg

        # 5. Redirect blocker never forwards auth headers
        handler = online_image._BlockRedirectsHandler()
        req = urllib.request.Request("https://api.openai.com/v1/images/generations")
        try:
            handler.redirect_request(req, None, 302, "Found", {}, "https://evil.example/steal")
            raise AssertionError("Expected redirect to be blocked")
        except urllib.error.HTTPError as exc:
            assert exc.code == 302

        # 6. Worker text-to-image only validation rejects reference image, video, LoRA, localOnly, unacknowledged billing
        base_req = {"action": "openai_image", "kind": "image", "prompt": "hi", "localOnly": False, "billingAcknowledged": True}
        for bad_patch in [
            {"localOnly": True},
            {"billingAcknowledged": False},
            {"kind": "video"},
            {"reference": "/tmp/ref.png"},
            {"referenceImages": ["/tmp/ref.png"]},
            {"referenceVideo": "/tmp/ref.mp4"},
            {"lora": "user_abc"},
        ]:
            req_case = dict(base_req, **bad_patch)
            try:
                worker.run_openai_image(req_case, Path(td))
                raise AssertionError(f"Expected rejection for {bad_patch}")
            except ValueError:
                pass
            try:
                worker.run_gemini_image(req_case, Path(td))
                raise AssertionError(f"Expected Gemini rejection for {bad_patch}")
            except ValueError:
                pass
    print("  [PASS] Online image API: mocked OpenAI + Gemini Interactions, blocked output, secret redaction, redirect block, T2I-only guards")


def test_swift_isolated_storage_models_lora_and_online_gates() -> None:
    with tempfile.TemporaryDirectory(prefix="md-b38-swift-") as td:
        root = Path(td)
        central = root / "central_comfy"
        comfy = root / "comfy_root"
        lora_storage = root / "central_loras"
        models_reg = root / "user_models.json"
        loras_reg = root / "user_loras.json"
        yaml_out = root / "extra_model_paths.yaml"

        # Synthetic safetensors files
        legacy_ckpt = comfy / "models/checkpoints/my_custom_sdxl.safetensors"
        write_synthetic_safetensors(legacy_ckpt, include_lora_pair=False, tag=1)

        collision_legacy = comfy / "models/diffusion_models/collide.safetensors"
        collision_central = central / "diffusion_models/collide.safetensors"
        write_synthetic_safetensors(collision_legacy, include_lora_pair=False, tag=2)
        write_synthetic_safetensors(collision_central, include_lora_pair=False, tag=3)

        exclusive_weight = root / "import_exclusive.safetensors"
        write_synthetic_safetensors(exclusive_weight, include_lora_pair=False, tag=4)

        lora_src = root / "my_adapter.safetensors"
        write_synthetic_safetensors(lora_src, include_lora_pair=True, tag=5)

        harness = root / "TestHarness.swift"
        harness.write_text(f"""
import Foundation

func expect(_ cond: @autoclosure () -> Bool, _ msg: String) {{
    if !cond() {{
        fputs("FAIL: \\(msg)\\n", stderr)
        exit(1)
    }}
}}

@main struct TestHarness {{
    static func main() {{
        do {{
            let central = URL(fileURLWithPath: {json.dumps(str(central))}, isDirectory: true)
            let comfy = URL(fileURLWithPath: {json.dumps(str(comfy))}, isDirectory: true)
            let loraStorage = URL(fileURLWithPath: {json.dumps(str(lora_storage))}, isDirectory: true)
            let modelsReg = URL(fileURLWithPath: {json.dumps(str(models_reg))})
            let lorasReg = URL(fileURLWithPath: {json.dumps(str(loras_reg))})
            let yamlOut = URL(fileURLWithPath: {json.dumps(str(yaml_out))})

            // 1. Primary category mapping across all 6 architectures
            expect(UserModelRegistry.primaryCategory(for: "zimage") == "diffusion_models", "zimage cat")
            expect(UserModelRegistry.primaryCategory(for: "redcraft") == "checkpoints", "redcraft cat")
            expect(UserModelRegistry.primaryCategory(for: "iniverse_flux") == "checkpoints", "iniverse_flux cat")
            expect(UserModelRegistry.primaryCategory(for: "moss") == "diffusion_models", "moss cat")
            expect(UserModelRegistry.primaryCategory(for: "krea2") == "diffusion_models", "krea2 cat")
            expect(UserModelRegistry.primaryCategory(for: "sdxl1") == "checkpoints", "sdxl1 cat")

            // 2. Safe migration helper: migrates legacy file -> central + symlink
            let legacy = URL(fileURLWithPath: {json.dumps(str(legacy_ckpt))})
            let mig = try CentralComfyModelStorage.migrateLegacyFile(from: legacy, category: "checkpoints", centralRoot: central, comfyRoot: comfy)
            expect(mig.status == .migrated, "expected migrated, got \\(mig.status)")
            let attrs = try FileManager.default.attributesOfItem(atPath: legacy.path)
            expect((attrs[.type] as? FileAttributeType) == .typeSymbolicLink, "legacy should become symlink")

            // 3. Collision preservation (same filename, different SHA256 -> preserve both)
            let collide = URL(fileURLWithPath: {json.dumps(str(collision_legacy))})
            let colRes = try CentralComfyModelStorage.migrateLegacyFile(from: collide, category: "diffusion_models", centralRoot: central, comfyRoot: comfy)
            expect(colRes.status == .collisionPreserved, "expected collisionPreserved")
            let colAttrs = try FileManager.default.attributesOfItem(atPath: collide.path)
            expect((colAttrs[.type] as? FileAttributeType) == .typeRegular, "colliding legacy must remain untouched")

            // 4. extra_model_paths.yaml generation
            try CentralComfyModelStorage.writeExtraModelPathsYAML(centralRoot: central, loraCentralRoot: loraStorage, to: yamlOut)
            let yamlText = try String(contentsOf: yamlOut, encoding: .utf8)
            expect(yamlText.contains("checkpoints: checkpoints") && yamlText.contains("diffusion_models: diffusion_models"), "yaml content")

            // 5. Import exclusive weight + create persistent custom model + bind LoRA to umodel_*
            let imported = try UserModelRegistry.importWeight(
                from: URL(fileURLWithPath: {json.dumps(str(exclusive_weight))}),
                category: "checkpoints",
                centralRoot: central,
                comfyRoot: comfy
            )
            let entry = try UserModelRegistry.upsertEntry(
                displayName: "My RedCraft Custom",
                baseProfile: "redcraft",
                primaryWeight: imported.filename,
                weightSHA256: imported.sha256,
                registryURL: modelsReg
            )
            expect(entry.id.hasPrefix("umodel_"), "custom model id prefix")
            expect(entry.primaryCategory == "checkpoints", "redcraft custom model should use checkpoints")

            let installedLoRA = try ManualLoRARegistry.install(
                source: URL(fileURLWithPath: {json.dumps(str(lora_src))}),
                root: comfy,
                model: entry.id,
                name: "Custom Adapter",
                strength: 0.8,
                registry: lorasReg,
                storageRoot: loraStorage,
                userModelsRegistry: modelsReg
            )
            expect(installedLoRA.compatibleModels == [entry.id], "LoRA must preserve custom model id binding")

            // 6. Hide & restore built-in model persistence
            try UserModelRegistry.hideBuiltIn(id: "zimage", registryURL: modelsReg)
            let hiddenAfterHide = try UserModelRegistry.load(from: modelsReg).hiddenBuiltInIds.contains("zimage")
            expect(hiddenAfterHide, "zimage hidden")
            try UserModelRegistry.restoreBuiltIn(id: "zimage", registryURL: modelsReg)
            let hiddenAfterRestore = try UserModelRegistry.load(from: modelsReg).hiddenBuiltInIds.contains("zimage")
            expect(!hiddenAfterRestore, "zimage restored")

            // 7. Distinguish remove entry only vs deleting exclusive weight, and protect shared TE/VAE
            let sharedEntry = try UserModelRegistry.upsertEntry(
                displayName: "Protected TE Test",
                baseProfile: "sdxl1",
                primaryWeight: "sd_xl_base_1.0.safetensors",
                registryURL: modelsReg
            )
            var refusedProtected = false
            do {{
                _ = try UserModelRegistry.removeEntry(id: sharedEntry.id, deleteWeightFile: true, centralRoot: central, comfyRoot: comfy, registryURL: modelsReg)
            }} catch {{
                refusedProtected = true
            }}
            expect(refusedProtected, "built-in protected weight must refuse deletion")
            let removedOnly = try UserModelRegistry.removeEntry(id: sharedEntry.id, deleteWeightFile: false, centralRoot: central, comfyRoot: comfy, registryURL: modelsReg)
            expect(!removedOnly, "remove entry only must not delete weight")

            let deletedExclusive = try UserModelRegistry.removeEntry(id: entry.id, deleteWeightFile: true, centralRoot: central, comfyRoot: comfy, registryURL: modelsReg)
            expect(deletedExclusive, "exclusive custom weight deletion should succeed")

            // 8. Online API gate & loopback check
            expect(NetworkReachabilityMonitor.isLoopbackURL("http://127.0.0.1:8188"), "127.0.0.1 loopback")
            expect(NetworkReachabilityMonitor.isLoopbackURL("http://localhost:17495"), "localhost loopback")
            expect(!NetworkReachabilityMonitor.isLoopbackURL("https://api.openai.com"), "openai not loopback")
            expect(!OnlineImageProvider.canInvokeAPI(provider: .openai, hasKey: false, billingAccepted: true, networkState: .online).allowed, "no key blocks API")
            expect(!OnlineImageProvider.canInvokeAPI(provider: .openai, hasKey: true, billingAccepted: false, networkState: .online).allowed, "no billing ack blocks API")
            expect(!OnlineImageProvider.canInvokeAPI(provider: .gemini, hasKey: true, billingAccepted: true, networkState: .offline).allowed, "offline blocks API")
            expect(OnlineImageProvider.canInvokeAPI(provider: .gemini, hasKey: true, billingAccepted: true, networkState: .online).allowed, "all 3 allow API")

            print("  [PASS] Swift isolated harness: 6-arch categories, migration+collision, YAML, umodel_*+LoRA install, hide/restore, delete protection, online gates")
        }} catch {{
            fputs("UNEXPECTED ERROR: \\(error)\\n", stderr)
            exit(1)
        }}
    }}
}}
""", encoding="utf-8")

        bin_path = root / "test_b38_harness"
        # Compile minimal standalone subset needed for the harness
        # We strip UI-only references by compiling all app sources except @main? Even simpler:
        # extract non-UI logic or compile StudioTheme + LocalModelManager + OnlineImageService + ManualLoRA + stubs.
        # Actually, since LocalModelManager/ManualLoRA/OnlineImageService reference Studio/PortabilitySetupManager/ModelProfileStore,
        # let's compile against a tiny stub file or invoke swiftc with our non-UI test driver!
        stub = root / "TestStubs.swift"
        stub.write_text("""
import Foundation
import SwiftUI
final class Studio: ObservableObject {
    var busy = false
    var status = ""
    var project = StubProject()
    var profileStore = ModelProfileStore.shared
    var activeLocalProfile: LocalModelProfile? { nil }
    var action = "zimage"
    var unsupportedLocalLoRAInfo: (id: String, label: String)? { nil }
    func selectLocalModel(_ m: String) {}
    func pickAsync(title: String, types: [Any], _ cb: @escaping ([URL]) -> Void) {}
}
struct StubProject {
    var localImageModel: String? = "zimage"
    var localImageLoRA: String? = ""
    var localLoRAStrength: Double? = nil
}
enum SupportedAPIProvider: String {
    case openai_image, gemini_image
    var keychainAccount: String { rawValue }
}
enum KeychainCredentialsStore {
    static let defaultService = "test"
    static func hasCredential(account: String, service: String = defaultService) -> Bool { false }
}
final class PortabilitySetupManager {
    static let shared = PortabilitySetupManager()
    func resolveAuthorizedComfyModelsRoot() -> URL? { nil }
    func chooseComfyModelsRoot(app: Studio, _ cb: @escaping (URL) -> Void) {}
}
struct LoRAProfile: Identifiable {
    let id: String; let name: String; let filename: String
    let compatibleModels: [String]; let defaultStrength: Double; let triggerNote: String?
}
struct LocalModelProfile: Identifiable {
    let id: String; let displayName: String; let architecture: String; let precision: String; let supportsLoRA: Bool
}
final class ModelProfileStore {
    static let shared = ModelProfileStore()
    var builtInImageModels: [LocalModelProfile] = []
    var imageModels: [LocalModelProfile] = []
    func compatibleLoRAs(for id: String) -> [LoRAProfile] { [] }
    func loraProfile(for id: String) -> LoRAProfile? { nil }
}
""", encoding="utf-8")

        cmd = [
            "swiftc", "-swift-version", "5",
            "-module-cache-path", "/tmp/md-v5-module-cache",
            "-parse-as-library",
            "-target", "arm64-apple-macos14.0",
            str(SRC / "StudioTheme.swift"),
            str(SRC / "LocalModelManager.swift"),
            str(SRC / "ManualLoRA.swift"),
            str(SRC / "OnlineImageService.swift"),
            str(stub),
            str(harness),
            "-o", str(bin_path),
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"Swift harness compile failed:\n{res.stderr}")
        run_res = subprocess.run([str(bin_path)], capture_output=True, text=True)
        if run_res.returncode != 0:
            raise RuntimeError(f"Swift harness failed:\n{run_res.stdout}\n{run_res.stderr}")
        print(run_res.stdout.strip())


def main() -> int:
    print("Running MotionDesk Build 38 isolated test suite...")
    test_python_user_models_all_six_architectures()
    test_online_image_mocked_http_and_redaction()
    test_swift_isolated_storage_models_lora_and_online_gates()
    print("ALL BUILD 38 ISOLATED TESTS PASSED.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
