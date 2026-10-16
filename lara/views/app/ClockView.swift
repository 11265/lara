//
//  ClockView.swift
//  lara
//
//  全局悬浮·第一视角（FPS）雷达：
//  悬浮层里是一个 WKWebView，加载电脑上 rr/fpv 服务提供的页面，
//  数据（自己朝向、其他人位置）由电脑的解析核心经局域网送到手机。
//
//  这里只有开关、地址、尺寸与诊断。
//

import SwiftUI

struct ClockView: View {
    @ObservedObject private var mgr = laramgr.shared

    @AppStorage("fpvURL") private var fpvURL: String = laramgr.fpvDefaultURL
    @AppStorage("fpvWidth") private var fpvWidth: Double = 0.92
    @AppStorage("fpvTop") private var fpvTop: Double = 56
    @AppStorage("fpvFullscreen") private var fpvFullscreen: Bool = false
    @AppStorage("fpvHeight") private var fpvHeight: Double = 0
    @AppStorage("fpvOrient") private var fpvOrient: String = "landscape"     // landscape（默认）/ portrait
    @AppStorage("fpvFov") private var fpvFov: Double = 90
    @AppStorage("fpvEye") private var fpvEye: Double = 1.6
    @AppStorage("fpvTau") private var fpvTau: Double = 70
    @AppStorage("fpvDist") private var fpvDist: Bool = true
    @AppStorage("fpvCross") private var fpvCross: Bool = true
    @AppStorage("fpvHud") private var fpvHud: Bool = true

    @State private var probe = ""
    @State private var probing = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { mgr.clockrunning },
                    set: { on in
                        if on {
                            mgr.startClock()
                        } else {
                            mgr.stopClock()
                        }
                    }
                )) {
                    Text("全局悬浮 · 第一视角")
                }
                .disabled(!mgr.rcready)

                Text(mgr.rcready
                     ? "远程调用已就绪，第一视角会自动显示，无需手动开启。"
                     : "请先在首页点击「初始化远程调用」。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("第一视角")
            } footer: {
                Text("悬浮层画在 SpringBoard 上，会浮在游戏之上且不吃触摸。数据不读内存、不读其它进程：手机通过局域网访问你电脑上的 rr/fpv 服务（server.py），页面每秒刷新。")
            }

            Section {
                TextField("http://192.168.137.1:18099/", text: Binding(
                    get: { fpvURL },
                    set: { fpvURL = $0; mgr.refreshOverlayUrl() }
                ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .font(.system(.footnote, design: .monospaced))
                Button {
                    Task { await runProbe() }
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        if probing { ProgressView() }
                    }
                }
                .disabled(probing)

                if !probe.isEmpty {
                    Text(probe)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(probe.hasPrefix("OK") ? .green : .orange)
                        .textSelection(.enabled)
                }
            } header: {
                Text("服务地址（电脑上的 rr/fpv）")
            } footer: {
                Text("电脑上执行：py -3.14 server.py --port 18099（不加 --fake 就是真数据）。地址填电脑在局域网/热点里的 IP，例如 http://192.168.137.1:18099/ 。改完地址一秒内自动重载，不用重启 lara。")
            }

            Section {
                Picker("方向", selection: Binding(
                    get: { fpvOrient },
                    set: { fpvOrient = $0; mgr.pushLayout() }
                )) {
                    Text("横屏（默认）").tag("landscape")
                    Text("竖屏").tag("portrait")
                }
                .pickerStyle(.segmented)
                Text("方向由你手选、不做自动判断：悬浮层按所选方向重新铺开，**不会重新加载页面**。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text("悬浮层盖住的地方，触摸会被系统丢弃（跨进程转发拿不到）。要完全不挡操作，用下面的预设把画面放到拇指区之外。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    presetButton("顶部条", full: false, w: 1.0, top: 0, h: 0.22)
                    presetButton("上半屏", full: false, w: 1.0, top: 0, h: 0.45)
                    presetButton("面板", full: false, w: 0.92, top: 56, h: 0)
                    presetButton("全屏", full: true, w: 1.0, top: 0, h: 0)
                }
                Toggle(isOn: Binding(
                    get: { fpvFullscreen },
                    set: { on in
                        fpvFullscreen = on
                        mgr.pushLayout()          // 立刻重排：铺满整屏 / 回到面板
                    }
                )) {
                    Text("铺满整屏（全屏）")
                }
                HStack {
                    Text("宽度")
                    Slider(value: Binding(
                        get: { fpvWidth },
                        set: { fpvWidth = $0; mgr.pushLayout() }
                    ), in: 0.3...1.0, step: 0.02)
                    Text("\(Int(fpvWidth * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
                .disabled(fpvFullscreen)
                HStack {
                    Text("顶部距离")
                    Slider(value: Binding(
                        get: { fpvTop },
                        set: { fpvTop = $0; mgr.pushLayout() }
                    ), in: 0...400, step: 4)
                    Text("\(Int(fpvTop))pt")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
                HStack {
                    Text("高度")
                    Slider(value: Binding(
                        get: { fpvHeight },
                        set: { fpvHeight = $0; mgr.pushLayout() }
                    ), in: 0...0.9, step: 0.05)
                    Text(fpvHeight == 0 ? "16:9" : "\(Int(fpvHeight * 100))% 屏高")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 66, alignment: .trailing)
                }
                .disabled(fpvFullscreen)
                Button("重新自检并显示") {
                    mgr.diagnoseClock()
                }
                .disabled(!mgr.rcready)
            } header: {
                Text("位置 · 尺寸 · 方向")
            } footer: {
                Text("尺寸按本机真实分辨率算，横屏时自动按目标窗口方向铺开（不重新加载页面）。想完全不挡操作就用「顶部条」或「上半屏」，下半屏留给游戏。")
            }

            Section {
                Toggle(isOn: Binding(get: { fpvCross },
                                     set: { fpvCross = $0; mgr.refreshOverlayUrl() })) {
                    Text("准星")
                }
                Toggle(isOn: Binding(get: { fpvDist },
                                     set: { fpvDist = $0; mgr.refreshOverlayUrl() })) {
                    Text("距离文字")
                }
                Toggle(isOn: Binding(get: { fpvHud },
                                     set: { fpvHud = $0; mgr.refreshOverlayUrl() })) {
                    Text("状态信息（连接/帧率/朝向）")
                }
                HStack {
                    Text("视场角 FOV")
                    Slider(value: Binding(get: { fpvFov },
                                          set: { fpvFov = $0; mgr.refreshOverlayUrl() }), in: 60...120, step: 2)
                    Text("\(Int(fpvFov))°")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
                HStack {
                    Text("眼高")
                    Slider(value: Binding(get: { fpvEye },
                                          set: { fpvEye = $0; mgr.refreshOverlayUrl() }), in: 0.6...2.6, step: 0.1)
                    Text(String(format: "%.1fm", fpvEye))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
                HStack {
                    Text("跟手（越小越跟手）")
                    Slider(value: Binding(get: { fpvTau },
                                          set: { fpvTau = $0; mgr.refreshOverlayUrl() }), in: 0...300, step: 10)
                    Text("\(Int(fpvTau))ms")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
            } header: {
                Text("画面")
            } footer: {
                Text("悬浮层完全不吃触摸（全部穿透给游戏），页面上没有任何按钮——所有开关都在这里。改动会在一秒内热重载生效，不用重启 lara。")
            }

            if !mgr.clockstatus.isEmpty {
                Section {
                    Text(mgr.clockstatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("状态")
                }
            }
        }
        .navigationTitle("第一视角")
    }

    /// 位置预设：一次把 全屏/宽度/顶部距离/高度 都设好并立刻重排。
    @ViewBuilder
    private func presetButton(_ title: String, full: Bool, w: Double, top: Double, h: Double) -> some View {
        Button(title) {
            fpvFullscreen = full
            fpvWidth = w
            fpvTop = top
            fpvHeight = h
            mgr.pushLayout()
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }

    /// 直接访问 <地址>/api/health，确认手机能不能连到那台电脑。
    private func runProbe() async {
        probing = true
        defer { probing = false }
        var base = fpvURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.hasPrefix("http") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/api/health") else {
            probe = "地址不合法：\(fpvURL)"
            return
        }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            probe = "OK \(code) · " + String(text.prefix(220))
        } catch {
            probe = "失败：\(error.localizedDescription)"
        }
    }
}
