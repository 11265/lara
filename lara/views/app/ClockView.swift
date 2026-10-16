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
                TextField("http://192.168.137.1:18099/", text: $fpvURL)
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
                HStack {
                    Text("宽度")
                    Slider(value: $fpvWidth, in: 0.3...1.0, step: 0.02)
                    Text("\(Int(fpvWidth * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
                HStack {
                    Text("顶部距离")
                    Slider(value: $fpvTop, in: 0...400, step: 4)
                    Text("\(Int(fpvTop))pt")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
                Button("重新自检并显示") {
                    mgr.diagnoseClock()
                }
                .disabled(!mgr.rcready)
            } header: {
                Text("尺寸")
            } footer: {
                Text("高度按 16:9 自动算。悬浮层不吃触摸，页面上的按钮按不到；准星/距离/FOV 想调就改地址后面的参数，例如 ?fov=100&eye=1.6&dist=0。")
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
