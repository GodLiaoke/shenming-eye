import re
import plistlib
import unittest
from html.parser import HTMLParser
from pathlib import Path


def static_page() -> str:
    here = Path(__file__).resolve()
    for parent in [here, *here.parents]:
        candidate = parent / "Phoenix-CodeV-Source" / "rust" / "codev-web" / "static" / "index.html"
        if candidate.is_file():
            return candidate.read_text(encoding="utf-8")
    raise AssertionError("shared radar index.html not found")


def ios_source(name: str) -> str:
    here = Path(__file__).resolve()
    candidate = here.parents[1] / "Sources" / name
    if not candidate.is_file():
        raise AssertionError(f"iOS source not found: {candidate}")
    return candidate.read_text(encoding="utf-8")


class RadarControlMarkupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.html = static_page()

    def test_has_one_radar_control_sheet_and_preserves_core_controls(self):
        html = self.html
        self.assertEqual(html.count('id="radarControlSheet"'), 1)
        self.assertEqual(html.count('id="radarControlToggle"'), 1)
        for control_id in ("viewRadar", "viewBoth", "view3d", "fitMap", "selectSelf", "filterSelf", "filterTeam", "filterEnemy", "markerScale", "rosterList"):
            self.assertEqual(html.count(f'id="{control_id}"'), 1, control_id)

    def test_removes_technical_display_controls_from_user_markup(self):
        html = self.html
        removed_ids = (
            "displaySettingsCard", "displaySettingsToggle", "drawToggle", "pixelScale",
            "teamLinger", "displayPerf", "hideTeam3d", "displayThreats", "displayPlayers",
            "displayMapName", "displayLegend", "displayLabelsRotate", "displayMapStructure",
            "displayLowLatency",
        )
        for control_id in removed_ids:
            self.assertNotIn(f'id="{control_id}"', html, control_id)

    def test_preserves_stable_rendering_paths_and_compact_help(self):
        html = self.html
        self.assertIn("stableYaw", html)
        self.assertEqual(len(re.findall(r'<canvas[^>]+id="map"', html)), 1)
        self.assertNotIn('id="mapStaticCanvas"', html)
        self.assertIn('id="mapEmptyHelpToggle"', html)
        self.assertIn('id="mapEmptySteps"', html)

    def test_js_uses_one_sheet_handler_and_keeps_url_debug_escapes(self):
        html = self.html
        self.assertIn("radarControlSheet", html)
        self.assertIn("radarControlToggle", html)
        self.assertIn("location.search.includes('perf')", html)
        self.assertIn("location.search.includes('full')", html)
        self.assertIn("query.get('full') === '1'", html)
        self.assertIn("lowLatencyMode = true", html)
        self.assertIn("const RADAR_NORTH_KEY = 'codev.radar.lockNorth'", html)
        self.assertNotIn("localStorage.getItem('codev.display.lockNorth')", html)

    def test_pip_mirrors_the_same_north_up_preference_as_the_radar_page(self):
        source = ios_source("RadarPiP.swift")
        self.assertIn("localStorage.getItem('codev.radar.lockNorth')", source)
        self.assertNotIn("localStorage.getItem('codev.display.lockNorth')", source)

    def test_new_sheet_overrides_legacy_mobile_layout_and_closes_before_self_pick(self):
        html = self.html
        self.assertIn("#rosterCard", html)
        self.assertIn("display: grid !important", html)
        self.assertIn("#mapControls", html)
        self.assertIn("backdrop-filter: none !important", html)
        self.assertIn("#radarControlToggle", html)
        self.assertIn("position: fixed !important", html)
        self.assertIn(".radar-control-section .filter-chip { min-height: 44px", html)
        self.assertIn("setRadarControlOpen(false);", html)

    def test_markup_has_balanced_html_containers(self):
        class BalanceParser(HTMLParser):
            VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

            def __init__(self):
                super().__init__()
                self.stack = []
                self.errors = []

            def handle_starttag(self, tag, attrs):
                if tag not in self.VOID:
                    self.stack.append(tag)

            def handle_endtag(self, tag):
                if tag not in self.stack:
                    self.errors.append((tag, "no open tag"))
                    return
                if self.stack[-1] != tag:
                    self.errors.append((tag, list(self.stack[-6:])))
                while self.stack:
                    if self.stack.pop() == tag:
                        break

        parser = BalanceParser()
        parser.feed(self.html)
        self.assertEqual(parser.errors, [])
        self.assertEqual(parser.stack, [])

    def test_map_first_empty_state_uses_lightweight_panel_and_quiet_background(self):
        html = self.html
        self.assertIn('<html lang="zh-CN" class="simple-panel">', html)
        self.assertIn('class="map-empty-card map-first-empty"', html)
        self.assertIn("/* v3 map-first empty state */", html)
        self.assertIn("background-color: #06111b", html)
        self.assertIn("linear-gradient(rgba(133,189,221,.045)", html)
        self.assertIn("backdrop-filter: blur(14px)", html)
        self.assertIn("width: min(306px, calc(100% - 42px))", html)

    def test_radar_os_skin_keeps_empty_state_low_and_map_as_visual_anchor(self):
        html = self.html
        self.assertIn('class="radar-hud-name"', html)
        self.assertIn("/* v4 radar os skin */", html)
        self.assertIn(".simple-panel .map-empty {", html)
        self.assertIn("place-items: end center;", html)
        self.assertIn(".simple-panel .map-panel::before", html)
        self.assertIn("letter-spacing: .18em", html)

    def test_simulator_review_fixes_activation_copy_and_accessibility(self):
        license_swift = ios_source("LicenseView.swift")
        console_swift = ios_source("MainConsoleView.swift")
        self.assertIn("private var ready: Bool { input.count == 24 }", license_swift)
        self.assertNotIn('.accessibilityLabel("本机雷达，(capabilities.localTitle)。(localDetail)")', console_swift)
        self.assertIn('.accessibilityLabel("本机雷达，\\(capabilities.localTitle)。\\(localDetail)")', console_swift)

    def test_console_scroll_reserves_space_for_fixed_launcher(self):
        console_swift = ios_source("MainConsoleView.swift")
        self.assertIn(".padding(.bottom, 112)", console_swift)

    def test_ios_webview_uses_cjk_safe_font_for_labeled_controls(self):
        html = self.html
        self.assertRegex(html, r'\.simple-panel \.map-tool,[^{]+\{\s*font-family: "PingFang SC"')
        self.assertRegex(html, r'\.simple-panel \.radar-control-toggle \* \{ font-family: "PingFang SC"')
        self.assertIn('const LABEL_FONT_STACK = \'"PingFang SC"', html)

    def test_simulator_review_can_force_room_url_without_local_engine(self):
        radar_swift = ios_source("RadarContainerView.swift")
        self.assertIn('ProcessInfo.processInfo.environment["PHOENIX_SIM_ROOM_URL"]', radar_swift)
        self.assertIn("let simulatedURL = URL(string: raw)", radar_swift)
        self.assertIn("return simulatedURL", radar_swift)

    def test_simulator_review_does_not_mask_customer_layout(self):
        webview_swift = ios_source("RadarWebView.swift")
        self.assertNotIn("classList.add('simple-panel')", webview_swift)
        self.assertNotIn("SIM_REVIEW_SIMPLE", webview_swift)

    def test_radar_has_explicit_back_to_connection_action(self):
        radar_swift = ios_source("RadarContainerView.swift")
        self.assertIn("返回连接节点", radar_swift)
        self.assertIn("leaveRadar()", radar_swift)
        theme_swift = ios_source("PhoenixTheme.swift")
        self.assertIn('Image(systemName: "arrow.left")', theme_swift)

    def test_console_explains_connection_gate_and_success_feedback(self):
        console_swift = ios_source("MainConsoleView.swift")
        self.assertIn("连接节点", console_swift)
        self.assertIn("本机游戏通道已启用", console_swift)
        self.assertIn("本机游戏通道尚未启动", console_swift)
        self.assertNotIn("手机 B 已连接", console_swift)
        self.assertIn("onStartConnection", console_swift)

    def test_native_theme_has_multi_accent_visual_system(self):
        theme_swift = ios_source("PhoenixTheme.swift")
        for token in ("auroraViolet", "auroraPink", "signalGo", "signalWait", "signalFault"):
            self.assertIn(token, theme_swift)

    def test_radar_web_skin_has_multi_accent_layers(self):
        html = self.html
        for token in ("--aurora-violet", "--aurora-pink", "--signal-mint", "aurora-signal-skin"):
            self.assertIn(token, html)

    def test_radar_landscape_skin_removes_redundant_header_and_prevents_double_tap_zoom(self):
        html = self.html
        self.assertIn("@media (orientation: landscape)", html)
        self.assertIn(".simple-panel .topbar { display: none !important; }", html)
        self.assertIn("touch-action: manipulation", html)
        self.assertIn("dblclick", html)
        self.assertIn("orientationchange", html)
        self.assertIn("visualViewport", html)

    def test_waiting_state_does_not_claim_phone_b_is_connected(self):
        app_model = ios_source("AppModel.swift")
        console = ios_source("MainConsoleView.swift")
        self.assertIn("等待本机游戏流量", app_model)
        self.assertIn("deviceConnected", console)
        self.assertNotIn("手机 B 尚未接入", console)

    def test_plain_signing_game_mode_uses_shadowrocket_without_vpn_jump(self):
        app_model = ios_source("AppModel.swift")
        controller = ios_source("GameTrafficController.swift")
        console = ios_source("MainConsoleView.swift")
        project = (Path(__file__).resolve().parents[1] / "project.yml").read_text(encoding="utf-8")
        self.assertIn("startGameTraffic", app_model)
        self.assertIn("NETunnelProviderManager", controller)
        self.assertIn("com.myrader.val.codev.tunnel", controller)
        self.assertIn("PhoenixTunnel", project)
        self.assertIn("shadowrocketFallback", app_model)
        self.assertIn("127.0.0.1", app_model)
        self.assertIn("localSocksLink", app_model)
        self.assertIn("本机小火箭节点", console)
        self.assertIn("不调用 startVPNTunnel()", app_model)
        game_mode = app_model.split("func startGameTraffic() async -> Bool", 1)[1].split("func stopGameTraffic()", 1)[0]
        self.assertNotIn("LocalRelay.stop()", game_mode)
        self.assertIn("重启会重新生成 SOCKS 密码", game_mode)

    def test_tunnel_extension_bridges_packet_flow_to_local_engine(self):
        here = Path(__file__).resolve().parents[1]
        provider = (here / "Tunnel" / "GamePacketTunnelProvider.swift").read_text(encoding="utf-8")
        self.assertIn("NEPacketTunnelProvider", provider)
        self.assertIn("packetFlow.readPackets", provider)
        self.assertIn("codev_tunnel_start", provider)
        self.assertIn("setTunnelNetworkSettings", provider)
        header = (here.parents[3] / "Phoenix-CodeV-Source" / "rust" / "codev-mobile" / "include" / "codev_mobile.h").read_text(encoding="utf-8")
        self.assertIn("codev_tunnel_start", header)

    def test_generated_tunnel_configuration_survives_xcodegen(self):
        here = Path(__file__).resolve().parents[1]
        info = plistlib.loads((here / "Tunnel" / "Info.plist").read_bytes())
        self.assertEqual(info["NSExtension"]["NSExtensionPointIdentifier"], "com.apple.networkextension.packet-tunnel")
        for name in ("Phoenix.entitlements", "Tunnel/PhoenixTunnel.entitlements"):
            entitlements = plistlib.loads((here / name).read_bytes())
            self.assertIn("packet-tunnel-provider", entitlements["com.apple.developer.networking.networkextension"])

    def test_tunnel_owns_engine_and_upload_while_main_app_is_backgrounded(self):
        here = Path(__file__).resolve().parents[1]
        provider = (here / "Tunnel" / "GamePacketTunnelProvider.swift").read_text(encoding="utf-8")
        self.assertIn("codev_engine_start", provider)
        self.assertIn("codev_engine_stop", provider)
        self.assertIn("handleAppMessage", provider)
        self.assertIn("PanelStreamMonitor.shared.start", provider)
        self.assertIn("O_NONBLOCK", provider)
        self.assertIn("loadUnaligned", provider)
        controller = ios_source("GameTrafficController.swift")
        self.assertIn("sendProviderMessage", controller)
        self.assertIn("NEVPNStatusDidChange", controller)
        self.assertNotIn('"password": access.proxyPassword', controller)

    def test_radar_hud_is_compact_not_a_large_capsule(self):
        theme = ios_source("PhoenixTheme.swift")
        self.assertIn("radar-status-compact", theme)
        self.assertIn("frame(width: 44, height: 44)", theme)

    def test_console_exposes_one_tap_game_mode(self):
        console = ios_source("MainConsoleView.swift")
        radar = ios_source("RadarContainerView.swift")
        modes = ios_source("RadarCapabilitySnapshot.swift")
        self.assertIn("本机雷达模式", modes)
        self.assertIn("双机雷达模式", modes)
        self.assertIn("RadarModeChooser", console)
        self.assertIn("ModeGuideCard", console)
        self.assertIn("共享雷达", console)
        self.assertIn("外网雷达链接已复制", console)
        self.assertIn("enterSelectedMode()", radar)

    def test_mode_specific_qr_is_not_shown_before_selection(self):
        console = ios_source("MainConsoleView.swift")
        self.assertIn("@State private var selectedMode: RadarUsageMode?", console)
        self.assertIn("if let selectedMode", console)
        self.assertIn("双机游戏节点", console)
        self.assertIn("本机小火箭节点", console)
        self.assertNotIn("局域网雷达二维码", console)

    def test_dual_mode_hides_pip_and_uses_external_share_link(self):
        console = ios_source("MainConsoleView.swift")
        radar = ios_source("RadarContainerView.swift")
        app_model = ios_source("AppModel.swift")
        self.assertIn("selectedMode == .singleDevice", console)
        self.assertIn("model.usageMode == .singleDevice", radar)
        self.assertIn("externalRadarShareLink", app_model)
        self.assertNotIn("lanRadarLink ?? grant.radarURL", console)

    def test_visible_ios_copy_does_not_reveal_client_decode_location(self):
        forbidden = ("本机解码", "本地解密", "客户端解密", "本机解析")
        sources_dir = Path(__file__).resolve().parents[1] / "Sources"
        combined = "\n".join(path.read_text(encoding="utf-8") for path in sources_dir.glob("*.swift"))
        for phrase in forbidden:
            self.assertNotIn(phrase, combined, phrase)

    def test_game_mode_prewarms_pip_before_live_coordinates(self):
        radar = ios_source("RadarContainerView.swift")
        self.assertIn("func start(webView: WKWebView?)", radar)
        self.assertIn("pip.start(webView:", radar)
        self.assertIn("isPreparing", radar)


if __name__ == "__main__":
    unittest.main()
