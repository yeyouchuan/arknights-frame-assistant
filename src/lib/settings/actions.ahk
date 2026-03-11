; == 设置操作 ==

; 初始化：订阅事件
EventBus.Subscribe("SettingsReset", HandleSettingsReset)
EventBus.Subscribe("SettingsSave", HandleSettingsSave)
EventBus.Subscribe("SettingsApply", HandleSettingsApply)
EventBus.Subscribe("SettingsCancel", HandleSettingsCancel)

; 处理重置按键设置事件
HandleSettingsReset(*) {
    Result := MessageBox.Confirm("  确定重置*所有*按键为默认设置吗 ？","重置按键设置")
    if (Result == "Yes") {
        EventBus.Publish("HotkeyOff")
        EventBus.Publish("UnsetSwitchKey")
        Config.ResetHotkeyToDefaults()
        EventBus.Publish("GuiUpdateHotkeyControls")
        EventBus.Publish("GuiUpdateCustomControls")
        Saver.SettingsIniWrite()
        Loader.LoadSettings()
        if(HotkeyController.HotkeyState == true) {
            EventBus.Publish("HotkeyOn")
        }
        EventBus.Publish("SetSwitchKey")
    }
}

; 处理保存设置事件
HandleSettingsSave(*) {
    EventBus.Publish("HotkeyOff")
    EventBus.Publish("UnsetSwitchKey")
    Saver.SettingsIniWrite()
    Loader.LoadSettings()
    if(HotkeyController.HotkeyState == true) {
        EventBus.Publish("HotkeyOn")
    }
    EventBus.Publish("SetSwitchKey")
    Saver.ResetGameStateIfNeeded()
    EventBus.Publish("GuiHide")
    MessageBox.Info("设置已保存！后续可双击右下角托盘区图标或通过右键菜单打开设置", "保存成功")
}

; 处理应用设置事件
HandleSettingsApply(*) {
    EventBus.Publish("HotkeyOff")
    EventBus.Publish("UnsetSwitchKey")
    Saver.SettingsIniWrite()
    Loader.LoadSettings()
    if(HotkeyController.HotkeyState == true) {
        EventBus.Publish("HotkeyOn")
    }
    EventBus.Publish("SetSwitchKey")
    Saver.ResetGameStateIfNeeded()
    MessageBox.Info("设置已应用！", "应用成功")
}

; 处理取消设置事件
HandleSettingsCancel(*) {
    ; 通过事件总线通知GUI恢复显示
    EventBus.Publish("GuiUpdateHotkeyControls")
    EventBus.Publish("GuiUpdateImportantControls")
    EventBus.Publish("GuiUpdateCustomControls")
    ; 通过事件总线通知GUI隐藏
    EventBus.Publish("GuiHide")
}
