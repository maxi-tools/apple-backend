//
//  Environment.swift
//
//
//  Created by Lexo Liu on 7/31/24.
//

import CWaterUI

@MainActor
public class WuiEnvironment {
    var inner: OpaquePointer
    init(_ inner: OpaquePointer) {
        self.inner = inner
    }

    /// Returns an environment for the `index`-th child, deriving a distinct
    /// `LocalStateScope` path so sibling reactive views keep independent local
    /// state across rebuilds. No-op clone if the env carries no scope.
    func childScope(_ index: Int) -> WuiEnvironment {
        WuiEnvironment(waterui_env_child_scope(inner, UInt(index))!)
    }

    /// Returns an environment whose `LocalStateScope` slot cursor is reset (same
    /// path), so a re-evaluated body re-keys its local slots identically.
    func resetScope() -> WuiEnvironment {
        WuiEnvironment(waterui_env_reset_scope(inner)!)
    }
    
    @MainActor deinit{
        waterui_drop_env(inner)
    }
}
