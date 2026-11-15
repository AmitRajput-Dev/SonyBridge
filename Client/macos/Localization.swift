//
//  Localization.swift
//  Runtime string lookup for text that SwiftUI can't localize on its own.
//
//  `Text("Literal")` and `Button("Literal")` take a LocalizedStringKey, so they already read
//  Localizable.strings. Strings that are built at runtime — helper parameters, ternaries, theme and
//  preset names, AppKit menu items — are plain `String`s and would stay English; they go through L().
//

import Foundation

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
