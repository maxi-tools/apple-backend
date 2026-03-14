//
//  Action.swift
//
//
//  Created by Lexo Liu on 5/14/24.
//
import CWaterUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
class Action {
    private var inner: OpaquePointer?
    private var env: WuiEnvironment?
    private let callback: (() -> Void)?

    init(inner: OpaquePointer, env: WuiEnvironment) {
        self.inner = inner
        self.env = env
        self.callback = nil
    }

    init(callback: @escaping () -> Void) {
        self.inner = nil
        self.env = nil
        self.callback = callback
    }

    func call() {
        if let callback {
            callback()
            return
        }
        guard let inner, let env else {
            fatalError("Action requires either a local callback or valid FFI action pointer")
        }
        waterui_call_action(inner, env.inner)
    }

    @MainActor deinit {
        if let inner {
            waterui_drop_action(inner)
        }
    }
}
