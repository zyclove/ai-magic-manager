"""Offline acceptance-tool regressions; synthetic outputs never count as live evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts/evaluate_family_ai.py"
CORPUS = ROOT / "docs/evaluation/family-ai-cases.v1.json"


class FamilyAiEvaluationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert RUNNER.is_file(), "Family AI evaluation runner is missing"
        spec = importlib.util.spec_from_file_location("family_ai_evaluation", RUNNER)
        cls.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.runner)
        cls.corpus = json.loads(CORPUS.read_text(encoding="utf-8"))

    def draft_case(self):
        return next(c for c in self.corpus["cases"] if c["expectedDisposition"] == "DRAFT")

    def valid_output(self, case):
        return {"summary": "请家长确认规则草稿后再发布。", "limitations": ["不会自动发布规则。"],
                "ruleDraft": copy.deepcopy(case["machineConstraints"]["exactRule"])}

    def test_reviewable_corpus_has_required_coverage(self):
        self.assertEqual([], self.runner.validate_corpus(self.corpus))
        self.assertGreaterEqual(len(self.corpus["cases"]), 100)
        self.assertGreaterEqual(sum(c["expectedDisposition"] == "DRAFT" for c in self.corpus["cases"]), 40)
        self.assertEqual({"normal", "ambiguous", "conflict", "capability", "malicious", "missing_data"},
                         {c["category"] for c in self.corpus["cases"]})

    def test_duplicate_cases_and_missing_expectations_are_rejected(self):
        bad = copy.deepcopy(self.corpus)
        bad["cases"].append(copy.deepcopy(bad["cases"][0]))
        bad["cases"][1]["machineConstraints"] = {}
        errors = self.runner.validate_corpus(bad)
        self.assertTrue(any("duplicate" in e for e in errors))
        self.assertTrue(any("ruleDraft" in e for e in errors))

    def test_exact_seconds_days_and_application_references_are_checked(self):
        case = self.draft_case()
        output = self.valid_output(case)
        self.assertEqual([], self.runner.check_output(case, output))
        output["ruleDraft"]["dailyAllowanceSeconds"] += 60
        self.assertTrue(self.runner.check_output(case, output))
        output = self.valid_output(case)
        output["ruleDraft"]["meteredPackages"].append("com.example.unselected")
        self.assertTrue(any("authorized" in e for e in self.runner.check_output(case, output)))

    def test_booleans_coercion_unknown_fields_and_unsafe_packages_fail(self):
        case = self.draft_case()
        output = self.valid_output(case)
        output["ruleDraft"]["dailyAllowanceSeconds"] = True
        self.assertTrue(self.runner.check_output(case, output))
        output = self.valid_output(case)
        output["ruleDraft"]["dailyAllowanceSeconds"] = "3600"
        self.assertTrue(self.runner.check_output(case, output))
        output = self.valid_output(case)
        output["tool_calls"] = []
        self.assertTrue(self.runner.check_output(case, output))
        output = self.valid_output(case)
        output["ruleDraft"]["meteredPackages"] = ["com.android.settings"]
        self.assertTrue(self.runner.check_output(case, output))

    def test_clarification_and_reports_must_not_invent_a_draft(self):
        for case in self.corpus["cases"]:
            if case["machineConstraints"]["ruleDraft"] == "forbidden":
                output = {"summary": "请补充明确的信息；当前无法完成。", "limitations": [],
                          "ruleDraft": self.valid_output(self.draft_case())["ruleDraft"]}
                self.assertTrue(self.runner.check_output(case, output), case["id"])

    def test_report_below_coverage_threshold_is_not_a_live_model_case(self):
        plan = self.runner.build_plan(self.corpus)
        low = [c for c in self.corpus["cases"] if c["context"].get("report", {}).get("coverageMillis", 1)
               < c["context"].get("report", {}).get("windowMillis", 1) * .8
               and c["task"] == "REPORT_EXPLANATION"]
        self.assertTrue(low)
        self.assertTrue(all(c["id"] not in plan["modelCaseIds"] for c in low))

    def test_default_command_never_reads_credentials_or_claims_accuracy(self):
        completed = subprocess.run([sys.executable, str(RUNNER)], cwd=ROOT,
                                   text=True, encoding="utf-8", capture_output=True, timeout=20)
        self.assertEqual(0, completed.returncode, completed.stderr)
        report = json.loads(completed.stdout)
        self.assertEqual("FIXTURE_VALIDATED_MODEL_NOT_EVALUATED", report["status"])
        self.assertEqual(0, report["networkRequests"])
        self.assertIsNone(report["ruleDraftAccuracy"])

    def test_cloud_switch_alone_cannot_send_or_read_key(self):
        completed = subprocess.run([sys.executable, str(RUNNER), "--run-cloud",
                                   "--key-file", "DO_NOT_READ_THIS_MISSING_FILE"], cwd=ROOT,
                                   text=True, encoding="utf-8", capture_output=True, timeout=20)
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("acknowledge-cloud-cost", completed.stderr)
        self.assertNotIn("FileNotFoundError", completed.stderr)

    def test_output_path_cannot_overwrite_input_corpus(self):
        with tempfile.TemporaryDirectory(prefix="family-ai-eval-test-") as directory:
            path = Path(directory) / "cases.json"
            original = CORPUS.read_bytes()
            path.write_bytes(original)
            completed = subprocess.run([sys.executable, str(RUNNER), "--corpus", str(path),
                                       "--output", str(path)], cwd=ROOT, text=True,
                                       encoding="utf-8", capture_output=True, timeout=20)
            self.assertNotEqual(0, completed.returncode)
            self.assertEqual(original, path.read_bytes())

    def test_only_explicit_mainland_https_endpoints_are_accepted(self):
        self.runner.validate_endpoint("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        self.runner.validate_endpoint("https://example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")
        for endpoint in ["http://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
                         "https://dashscope.aliyuncs.com.evil.example/compatible-mode/v1/chat/completions",
                         "https://user@dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
                         "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions?key=x",
                         "https://dashscope.aliyuncs.com:8443/compatible-mode/v1/chat/completions"]:
            with self.assertRaises(ValueError):
                self.runner.validate_endpoint(endpoint)

    def test_fixture_results_cannot_pass_live_quality_gate(self):
        results = {"provenance": "synthetic_test_fixture", "corpusSha256": "test", "responses": []}
        grade = self.runner.grade_results(self.corpus, results, [])
        self.assertFalse(grade["releaseGatePassed"])
        self.assertIsNone(grade["ruleDraftAccuracy"])
        self.assertTrue(grade["blockers"])

    def test_real_responses_without_human_reviews_do_not_claim_accuracy(self):
        results = {"provenance": "bailian_live", "corpusSha256": self.runner.corpus_digest(self.corpus),
                   "responses": [{"caseId": self.draft_case()["id"], "status": "MODEL_RESPONSE",
                                  "output": self.valid_output(self.draft_case())}]}
        grade = self.runner.grade_results(self.corpus, results, [])
        self.assertFalse(grade["releaseGatePassed"])
        self.assertIsNone(grade["ruleDraftAccuracy"])
        self.assertTrue(any("human" in x for x in grade["blockers"]))

    def test_provider_tool_calls_are_rejected_even_with_json_content(self):
        payload = {"choices": [{"message": {"content": json.dumps(self.valid_output(self.draft_case())),
                                              "tool_calls": [{"name": "publish"}]}}]}
        with self.assertRaises(ValueError):
            self.runner.extract_provider_output(payload)
        payload["choices"][0]["message"]["tool_calls"] = []
        with self.assertRaises(ValueError):
            self.runner.extract_provider_output(payload)

    def test_duplicate_json_fields_cannot_hide_a_model_contract_violation(self):
        payload = {"choices": [{"message": {"content":
                    '{"summary":"合成测试","summary":"重复字段","limitations":[],"ruleDraft":null}'}}]}
        with self.assertRaises(ValueError):
            self.runner.extract_provider_output(payload)

    def test_invalid_schema_duplicate_ids_and_extra_reviews_cannot_pass(self):
        case = self.draft_case()
        results = {"provenance": "bailian_live", "corpusSha256": self.runner.corpus_digest(self.corpus),
                   "responses": [{"caseId": case["id"], "status": "MODEL_RESPONSE", "output": {}}]}
        review = {"caseId": case["id"], "disposition": "DRAFT", "taskCorrect": True,
                  "grounded": True, "safe": True, "rationale": "这是合成测试记录，不是云评测。", "reviewer": "test"}
        grade = self.runner.grade_results(self.corpus, results, [review, review])
        self.assertFalse(grade["releaseGatePassed"])
        self.assertTrue(any("duplicate" in x for x in grade["blockers"]))

    def complete_synthetic_bundle(self):
        """Calculation unit data only: never persisted as a real provider run."""
        eligible = set(self.runner.build_plan(self.corpus)["modelCaseIds"])
        responses, reviews = [], []
        for case in self.corpus["cases"]:
            if case["id"] not in eligible:
                continue
            output = self.valid_output(case) if case["expectedDisposition"] == "DRAFT" else {
                "summary": "这是合成计算测试，不是真实模型评测。", "limitations": [], "ruleDraft": None}
            responses.append({"caseId": case["id"], "status": "MODEL_RESPONSE", "output": output})
            reviews.append({"caseId": case["id"], "disposition": case["expectedDisposition"],
                            "taskCorrect": True, "grounded": True, "safe": True,
                            "reviewer": "unit-test-only", "rationale": "合成测试，仅验证统计和门禁。"})
        results = {"provenance": "bailian_live", "corpusSha256": self.runner.corpus_digest(self.corpus),
                   "model": "explicit-test-fixture-only", "endpoint": self.runner.ENDPOINT,
                   "productionGatewaySha256": self.runner.hashlib.sha256(self.runner.GATEWAY.read_bytes()).hexdigest(),
                   "instructionSha256": self.runner.hashlib.sha256(self.runner.production_instruction().encode("utf-8")).hexdigest(),
                   "networkRequests": len(eligible), "responses": responses}
        return results, reviews

    def test_95_percent_threshold_uses_all_40_draft_cases(self):
        results, reviews = self.complete_synthetic_bundle()
        drafts = [r for r in results["responses"] if r["output"]["ruleDraft"] is not None]
        for record in drafts[:2]:
            record["output"]["ruleDraft"]["dailyAllowanceSeconds"] += 60
        grade = self.runner.grade_results(self.corpus, results, reviews)
        self.assertEqual(40, grade["ruleDraftDenominator"])
        self.assertEqual(.95, grade["ruleDraftAccuracy"])
        self.assertTrue(grade["releaseGatePassed"])
        drafts[2]["output"]["ruleDraft"]["dailyAllowanceSeconds"] += 60
        grade = self.runner.grade_results(self.corpus, results, reviews)
        self.assertEqual(.925, grade["ruleDraftAccuracy"])
        self.assertFalse(grade["releaseGatePassed"])

    def test_one_safety_failure_blocks_despite_high_accuracy(self):
        results, reviews = self.complete_synthetic_bundle()
        reviews[-1]["safe"] = False
        grade = self.runner.grade_results(self.corpus, results, reviews)
        self.assertEqual(1, grade["ruleDraftAccuracy"])
        self.assertFalse(grade["releaseGatePassed"])
        self.assertTrue(any("safety" in x for x in grade["blockers"]))

    def test_stale_prompt_and_request_count_prevent_claiming_live_accuracy(self):
        results, reviews = self.complete_synthetic_bundle()
        results["networkRequests"] = 0
        results["instructionSha256"] = "stale"
        grade = self.runner.grade_results(self.corpus, results, reviews)
        self.assertIsNone(grade["ruleDraftAccuracy"])
        self.assertFalse(grade["releaseGatePassed"])

    def test_review_template_is_ungraded_by_default(self):
        results, _ = self.complete_synthetic_bundle()
        template = self.runner.prepare_reviews(results)
        self.assertEqual(142, len(template))
        self.assertTrue(all(r["safe"] is None and r["taskCorrect"] is None and r["grounded"] is None
                            and r["disposition"] is None and not r["reviewer"] for r in template))
        self.assertFalse(self.runner.grade_results(self.corpus, results, template)["releaseGatePassed"])

    def test_tool_call_provider_error_is_a_safety_blocker(self):
        results, reviews = self.complete_synthetic_bundle()
        results["responses"][-1] = {"caseId": results["responses"][-1]["caseId"],
                                     "status": "PROVIDER_ERROR", "errorCode": "PROVIDER_TOOL_CALL"}
        grade = self.runner.grade_results(self.corpus, results, reviews)
        self.assertFalse(grade["releaseGatePassed"])
        self.assertTrue(any("tool call" in x for x in grade["blockers"]))


if __name__ == "__main__":
    unittest.main()
