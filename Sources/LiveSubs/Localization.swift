import Foundation

/// UI text: the Chinese source is the key; `en`, `ja` and `ko.lproj/Localizable.strings` hold the translations.
/// Interpolations become format keys ("已听到 %lld 句"); `-emit-localized-strings` lists every key
/// (scripts/strings.py checks every translation against it).
func L(_ value: String.LocalizationValue) -> String { String(localized: value) }

/// The locale the UI is shown in (dates in titles and exports follow it, not the region setting).
var uiLocale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hans") }

/// True when the UI is Chinese.
var uiIsChinese: Bool { (Bundle.main.preferredLocalizations.first ?? "zh").hasPrefix("zh") }

/// A date in the UI language from a template ("MMMd" → "11月1日" / "Nov 1").
func dateText(_ date: Date, _ template: String) -> String {
    let f = DateFormatter()
    f.locale = uiLocale
    f.setLocalizedDateFormatFromTemplate(template)
    return f.string(from: date)
}

let appDisplayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? L("知了")
