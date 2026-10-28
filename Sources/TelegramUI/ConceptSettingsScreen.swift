import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import ConceptFeatures
import AIAgentCore

/// Settings ▸ Additions: a switch for each of the concept's additions and one for all of them, which brings back
/// plain Telegram. The texts are not in the language packs, so they are given here in Russian and English.
private final class ConceptSettingsScreenArguments {
    let toggleAll: (Bool) -> Void
    let toggleFeature: (ConceptFeature, Bool) -> Void
    let setSpeed: (Double) -> Void
    let resetDemo: () -> Void

    init(toggleAll: @escaping (Bool) -> Void, toggleFeature: @escaping (ConceptFeature, Bool) -> Void, setSpeed: @escaping (Double) -> Void, resetDemo: @escaping () -> Void) {
        self.toggleAll = toggleAll
        self.toggleFeature = toggleFeature
        self.setSpeed = setSpeed
        self.resetDemo = resetDemo
    }
}

private enum ConceptSettingsScreenSection: Int32 {
    case all
    case features
    case simulator
    case speed
    case reset
}

private enum ConceptSettingsScreenEntry: ItemListNodeEntry {
    enum StableId: Hashable {
        case all
        case allFooter
        case header(Int32)
        case feature(ConceptFeature)
        case speed(Double)
        case reset
        case footer(Int32)
    }

    case all(String, Bool)
    case allFooter(String)
    case header(ConceptSettingsScreenSection, String)
    case feature(ConceptSettingsScreenSection, index: Int, ConceptFeature, title: String, text: String, value: Bool, enabled: Bool)
    case speed(index: Int, title: String, value: Double, selected: Bool, enabled: Bool)
    case reset(String, enabled: Bool)
    case footer(ConceptSettingsScreenSection, String)

    var section: ItemListSectionId {
        switch self {
        case .all, .allFooter:
            return ConceptSettingsScreenSection.all.rawValue
        case .speed:
            return ConceptSettingsScreenSection.speed.rawValue
        case .reset:
            return ConceptSettingsScreenSection.reset.rawValue
        case let .header(section, _), let .feature(section, _, _, _, _, _, _), let .footer(section, _):
            return section.rawValue
        }
    }

    var sortIndex: Int {
        switch self {
        case .all:
            return 0
        case .allFooter:
            return 1
        case let .header(section, _):
            return Int(section.rawValue) * 1000
        case let .feature(section, index, _, _, _, _, _):
            return Int(section.rawValue) * 1000 + 1 + index
        case let .speed(index, _, _, _, _):
            return Int(ConceptSettingsScreenSection.speed.rawValue) * 1000 + 1 + index
        case .reset:
            return Int(ConceptSettingsScreenSection.reset.rawValue) * 1000 + 1
        case let .footer(section, _):
            return Int(section.rawValue) * 1000 + 999
        }
    }

    var stableId: StableId {
        switch self {
        case .all:
            return .all
        case .allFooter:
            return .allFooter
        case let .header(section, _):
            return .header(section.rawValue)
        case let .feature(_, _, feature, _, _, _, _):
            return .feature(feature)
        case let .speed(_, _, value, _, _):
            return .speed(value)
        case .reset:
            return .reset
        case let .footer(section, _):
            return .footer(section.rawValue)
        }
    }

    static func <(lhs: ConceptSettingsScreenEntry, rhs: ConceptSettingsScreenEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ConceptSettingsScreenArguments
        switch self {
        case let .all(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleAll(value)
            })
        case let .allFooter(text), let .footer(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .feature(_, _, feature, title, text, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, text: text, value: value, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleFeature(feature, value)
            })
        case let .speed(_, title, value, selected, enabled):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .right, checked: selected, enabled: enabled, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setSpeed(value)
            })
        case let .reset(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .destructive : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.resetDemo()
            })
        }
    }
}

private func conceptSettingsText(_ strings: PresentationStrings, _ russian: String, _ english: String) -> String {
    return strings.baseLanguageCode == "ru" ? russian : english
}

private func conceptFeatureTitle(_ feature: ConceptFeature, strings: PresentationStrings) -> (title: String, text: String) {
    switch feature {
    case .aiAgentStyle:
        return (conceptSettingsText(strings, "Стиль AI-агентов", "AI Agent Style"), conceptSettingsText(strings, "Боты на _ai — это Data AI: своя аватарка и статус работы в чатах", "Bots ending in _ai appear as Data AI, with their work shown live in Chats"))
    case .aiAgentDemo:
        return (conceptSettingsText(strings, "Демо-агент", "Demo Agent"), conceptSettingsText(strings, "Отвечает в чатах _ai-ботов, ничего не отправляя боту", "Answers in _ai bot chats without sending anything to the bot"))
    case .aiAgentAscii:
        return (conceptSettingsText(strings, "ASCII-анимации", "ASCII Animations"), conceptSettingsText(strings, "Печать кода, проявление превью и итогов работы", "Typing code, revealing previews and work summaries"))
    }
}

private func conceptSettingsScreenEntries(presentationData: PresentationData) -> [ConceptSettingsScreenEntry] {
    let strings = presentationData.strings
    let isAllEnabled = ConceptFeatures.isAllEnabled

    var entries: [ConceptSettingsScreenEntry] = []
    entries.append(.all(conceptSettingsText(strings, "Все дополнения", "All Additions"), isAllEnabled))
    entries.append(.allFooter(conceptSettingsText(strings, "Выключите, чтобы вернуть обычный Telegram. Изменения применяются, когда экран открывается заново.", "Turn off for plain Telegram. Changes apply when a screen is opened again.")))

    let sections: [(ConceptSettingsScreenSection, String, [ConceptFeature])] = [
        (.features, conceptSettingsText(strings, "AI-агенты", "AI Agents"), ConceptFeature.allCases.filter { !$0.isSimulatorOnly }),
        (.simulator, conceptSettingsText(strings, "Только в симуляторе", "Simulator Only"), ConceptFeature.allCases.filter { $0.isSimulatorOnly && $0.isAvailable })
    ]
    for (section, header, features) in sections where !features.isEmpty {
        entries.append(.header(section, header))
        for (index, feature) in features.enumerated() {
            let (title, text) = conceptFeatureTitle(feature, strings: strings)
            entries.append(.feature(section, index: index, feature, title: title, text: text, value: isAllEnabled && ConceptFeatures.isSwitchedOn(feature), enabled: isAllEnabled))
        }
        if section == .simulator {
            entries.append(.footer(section, conceptSettingsText(strings, "Выдуманные данные никогда не попадают в сборку для телефона.", "Made-up content never gets into a device build.")))
        }
    }

    if ConceptFeature.aiAgentDemo.isAvailable {
        let isDemoEnabled = ConceptFeatures.isEnabled(.aiAgentDemo)
        entries.append(.header(.speed, conceptSettingsText(strings, "Скорость демо-агента", "Demo Agent Speed")))
        let speeds: [(Double, String)] = [
            (0.5, conceptSettingsText(strings, "Медленно, для записи", "Slow, for recording")),
            (1.0, conceptSettingsText(strings, "Обычно", "Normal")),
            (2.0, conceptSettingsText(strings, "Быстро", "Fast"))
        ]
        let current = AIAgentDemoSettings.speed
        for (index, speed) in speeds.enumerated() {
            entries.append(.speed(index: index, title: speed.1, value: speed.0, selected: abs(current - speed.0) < 0.01, enabled: isDemoEnabled))
        }
        entries.append(.reset(conceptSettingsText(strings, "Удалить ответы демо-агента", "Delete Demo Agent Replies"), enabled: isDemoEnabled))
        entries.append(.footer(.reset, conceptSettingsText(strings, "Убирает из чатов всё, что написал демо-агент, и ваши сообщения ему. Сообщения настоящего бота не трогает.", "Removes everything the demo agent wrote, and your messages to it, from the chats. The real bot's messages stay.")))
    }
    return entries
}

public func conceptSettingsScreen(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController) -> Void)?
    let speedPromise = ValuePromise<Double>(AIAgentDemoSettings.speed, ignoreRepeated: true)
    let arguments = ConceptSettingsScreenArguments(
        toggleAll: { value in
            ConceptFeatures.setAllEnabled(value)
        },
        toggleFeature: { feature, value in
            ConceptFeatures.setSwitchedOn(feature, value)
        },
        setSpeed: { value in
            AIAgentDemoSettings.speed = value
            speedPromise.set(value)
        },
        resetDemo: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let strings = presentationData.strings
            let actionSheet = ActionSheetController(presentationData: presentationData)
            actionSheet.setItemGroups([
                ActionSheetItemGroup(items: [
                    ActionSheetTextItem(title: conceptSettingsText(strings, "Ответы демо-агента и ваши сообщения ему исчезнут из чатов.", "The demo agent's replies and your messages to it will disappear from the chats.")),
                    ActionSheetButtonItem(title: conceptSettingsText(strings, "Удалить", "Delete"), color: .destructive, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        let _ = AIAgentDemoEngine.shared(context: context).reset().start()
                    })
                ]),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: strings.Common_Cancel, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                    })
                ])
            ])
            presentControllerImpl?(actionSheet)
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        .single(Void()) |> then(ConceptFeatures.updated),
        speedPromise.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, _, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(conceptSettingsText(presentationData.strings, "Дополнения", "Additions")),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: conceptSettingsScreenEntries(presentationData: presentationData), style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}

/// The title of the Additions row in Settings.
func conceptSettingsTitle(strings: PresentationStrings) -> String {
    return conceptSettingsText(strings, "Дополнения", "Additions")
}
