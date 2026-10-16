//
//  captureprotect.swift
//  lara
//
//  全界面防录屏 / 防截屏（只作用于本应用自己）。
//
//  做法：把应用窗口里的整个界面搬进一个开启 secureTextEntry 的 UITextField。
//  UIKit 把安全输入层判定为不可被捕获，并连同其整棵子树一起排除在截图与录屏
//  之外，所以应用的每一屏都受保护。全程进程内完成：不用内核读写，不用远程调用，
//  也不影响系统里其它应用。
//
//  安全容器自身永不参与命中测试（hitTest 不返回自己），因此界面的触摸、滚动、
//  键盘都照常工作；它只是把内容包住。
//

import SwiftUI
import UIKit

/// 仅作容器：自己不接收触摸，子视图照常可点。
final class CaptureShieldField: UITextField {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

enum CaptureShield {
    private static weak var shield: CaptureShieldField?

    static var isInstalled: Bool { shield != nil }

    /// 把窗口里的整个界面搬进安全输入层。可重复调用，已安装时直接返回。
    @discardableResult
    static func install() -> Bool {
        if shield != nil { return true }
        guard let window = keyWindow(), let rootView = window.rootViewController?.view else { return false }
        if rootView is CaptureShieldField { return false }

        let field = CaptureShieldField(frame: window.bounds)
        field.isSecureTextEntry = true
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.textColor = .clear
        field.text = " "                        // 让 UIKit 走安全渲染路径；颜色透明，看不到圆点
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        field.isUserInteractionEnabled = true   // 子视图必须继续接收触摸

        window.addSubview(field)
        field.addSubview(rootView)
        rootView.translatesAutoresizingMaskIntoConstraints = true
        rootView.frame = field.bounds
        rootView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        shield = field
        globallogger.log("(shield) 全界面防录屏/防截屏已启用")
        return true
    }

    /// 还原成普通层级（关闭开关时使用）。
    static func uninstall() {
        guard let field = shield else { return }
        if let window = field.superview {
            let rootView = field.subviews.first
            if let rootView {
                rootView.removeFromSuperview()
                window.addSubview(rootView)
                rootView.frame = window.bounds
                rootView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            }
            field.removeFromSuperview()
        }
        shield = nil
        globallogger.log("(shield) 全界面防录屏/防截屏已关闭")
    }

    /// 按设置与当前窗口状态同步一次：回前台、切换开关、窗口重建后调用。
    static func sync(enabled: Bool) {
        if enabled {
            _ = install()
        } else {
            uninstall()
        }
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        return scenes.first?.windows.first
    }
}
