//
//  ClockView.swift
//  lara
//
//  现在整个应用只保留一件事：远程调用就绪后显示全局悬浮时间。
//  这里只有开关与诊断。
//

import SwiftUI

struct ClockView: View {
    @ObservedObject private var mgr = laramgr.shared

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
                    Text("全局悬浮时钟")
                }
                .disabled(!mgr.rcready)

                Text(mgr.rcready
                     ? "远程调用已就绪，悬浮时间会自动显示，无需手动开启。"
                     : "请先在首页点击「初始化远程调用」。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Button("重新自检并显示") {
                    mgr.diagnoseClock()
                }
                .disabled(!mgr.rcready)
            } header: {
                Text("悬浮时钟")
            } footer: {
                Text("时间胶囊画在 SpringBoard 上，会浮在应用之上；退出 lara 后停止。检测到录屏/镜像时胶囊与窗口会自动隐藏，录完恢复。\n\n本应用自身的每一屏都由「全界面防录屏/防截屏」保护（可在设置里开关）：整个界面被放进 secureTextEntry 安全输入层，截图与录屏里显示为空白。\n\n自检会把 [1/9]…[9/9] 每一步写进日志。")
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
        .navigationTitle("时钟")
    }
}
