from pathlib import Path
r=Path(__file__).resolve().parents[1]
t=(r/'ParcelKeeper/Views/TaobaoTrialView.swift').read_text()
m=(r/'ParcelKeeper/Views/MallImportView.swift').read_text()
assert 'let readOnly: Bool' in t, 'Taobao login sheet missing read-only guard'
assert 'guard !busy, !store.isHistoricalSnapshot else' in t, 'Taobao fetch missing read-only guard'
clear=m.split('private func clearSession()',1)[1].split('private func fetch()',1)[0]
assert 'operationID == id' in clear, 'clear completion lacks generation guard'
assert 'MallBrowserContext.detach' in clear, 'clear can remove the newly installed platform browser context'
home=(r/'ParcelKeeper/Views/HomeView.swift').read_text()
settings=(r/'ParcelKeeper/Views/SettingsView.swift').read_text()
widget=(r/'ParcelKeeperWidget/TrainTicketWidgets.swift').read_text()
refresh=(r/'ParcelKeeper/Services/TrackingRefreshService.swift').read_text()
assert 'SmartShipmentParser.parseReport(text)' in home and 'report.hasFailures' in home
assert 'await store.reconcileReminders()' in settings and 'importedShipments' not in settings
assert 'expectedBinding: binding' in widget
assert 'sourceURL: before.platformLogisticsURL' in refresh
print('PASS UI source contracts, not SwiftUI/device tests')
