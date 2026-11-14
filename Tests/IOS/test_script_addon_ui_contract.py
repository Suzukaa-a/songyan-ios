import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ScriptAddonUXContractTests(unittest.TestCase):
    """Source-level guards for the script pages' UX fixes. HostApp has no unit-test target,
    so these keep the accessibility, error-copy and layout regressions from silently
    returning while the existing behaviour stays covered by ScriptAddonKit tests."""

    def read(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_run_errors_go_through_the_failure_mapping(self):
        center = self.read("Apps/HostApp/ScriptAddonCenter.swift")
        self.assertIn("Self.userMessage(for:", center)
        self.assertNotIn("message + String(format: String(localized:", center)
        try_run = center.split("func tryRun", 1)[1].split("// MARK: - Empty-page resources", 1)[0]
        self.assertNotIn("error.localizedDescription", try_run)

    def test_list_rows_are_buttons_with_named_toggles_and_chevrons(self):
        view = self.read("Apps/HostApp/ScriptAddonCenterView.swift")
        self.assertIn("NavigationLink {", view)
        self.assertIn("ScriptAddonDetailView(center: center, addon: addon)", view)
        self.assertIn("String(format: String(localized: \"启用 %@\")", view)
        self.assertIn(".disabled(center.availabilityNote(addon) != nil)", view)
        self.assertIn("String(localized: \"重新确认\")", view)
        self.assertIn(".accessibilityValue(", view)

    def test_large_type_actions_are_in_the_scrolling_content(self):
        views = self.read("Apps/HostApp/ScriptAddonViews.swift")
        self.assertIn("dynamicTypeSize >= .accessibility1", views)
        self.assertIn(".safeAreaInset(edge: .bottom)", views)
        self.assertIn(".disabled(trimmedSource.isEmpty)", views)

    def test_detail_page_owns_settings_as_a_child(self):
        views = self.read("Apps/HostApp/ScriptAddonViews.swift")
        self.assertIn("struct ScriptAddonDetailView", views)
        self.assertIn("NavigationLink {\n                    ScriptAddonSettingsView", views)
        self.assertIn("String(localized: \"重新确认\")", views)
        self.assertIn("脚本的设置和密钥也会一起删除，且无法撤销。", views)

    def test_try_run_result_has_no_fixed_clipping_height(self):
        views = self.read("Apps/HostApp/ScriptAddonViews.swift")
        self.assertNotIn("frame(maxHeight: 140)", views)
        self.assertIn("String(localized: \"复制结果\")", views)
        self.assertIn("String(localized: \"日志\")", views)
        self.assertIn("String(localized: \"结果\")", views)

    def test_empty_editor_and_link_sheet_disable_or_explain(self):
        views = self.read("Apps/HostApp/ScriptAddonViews.swift")
        view = self.read("Apps/HostApp/ScriptAddonCenterView.swift")
        self.assertIn("String(localized: \"插入最小示例\")", views)
        self.assertIn("String(localized: \"在这里粘贴或编写脚本\")", views)
        self.assertIn("只支持 HTTPS 链接；脚本只在这里下载一次，之后可在详情页检查更新。", view)
        self.assertIn("String(localized: \"下载中…\")", view)
        self.assertIn("String(localized: \"添加第一个脚本\")", view)

    def test_try_run_returns_the_failure_with_the_console_lines(self):
        bridge = self.read("Apps/HostApp/ScriptAddonBridge.swift")
        self.assertIn("var failure: ScriptAddonFailure?", bridge)
        self.assertIn("SONGYAN_SCRIPT_ERROR_SCRIPT: return .script(message:", bridge)
        self.assertNotIn("var errorMessage", bridge)
        views = self.read("Apps/HostApp/ScriptAddonViews.swift")
        self.assertIn("ScriptAddonCenter.userMessage(for: failure)", views)
        center = self.read("Apps/HostApp/ScriptAddonCenter.swift")
        self.assertIn("failure.scriptMessage", center)

    def test_network_disclosure_counts_url_settings_and_shows_the_timeout(self):
        views = self.read("Apps/HostApp/ScriptAddonViews.swift")
        self.assertIn("declarations.dependsOnNetwork", views)
        self.assertIn("declarations.hasURLSetting", views)
        self.assertIn("你在设置里填的地址", views)
        self.assertIn("最长运行 %lld 分钟", views)
        self.assertNotIn("connectHosts.isEmpty", views)

    def test_linked_download_is_bounded_while_reading(self):
        center = self.read("Apps/HostApp/ScriptAddonCenter.swift")
        download = center.split("private static func downloadOverHTTPS", 1)[1].split("// MARK:", 1)[0]
        self.assertIn("SONGYAN_SCRIPT_SHIPPED_SOURCE_BYTES", download)
        self.assertIn("URLSession.shared.bytes", download)
        self.assertNotIn("expectedContentLength", download)

    def test_user_strings_are_plain_not_escaped(self):
        for relative in ("Apps/HostApp/ScriptAddonCenter.swift", "Apps/HostApp/HostApp.swift"):
            self.assertNotIn("\\u{8", self.read(relative), relative)


if __name__ == "__main__":
    unittest.main()
