-- ============================================================================
-- SettingsUI.lua — 设置面板（可从暂停菜单 / 开始界面调起）
-- 包含：鼠标灵敏度、游戏音乐、游戏音效
-- ============================================================================

local GameConfig = require("config.GameConfig")
local AudioManager = require("core.AudioManager")
local MobileControls = require("ui.MobileControls")
local TutorialUI = require("ui.TutorialUI")
local UI = require("urhox-libs/UI")

local SettingsUI = {}

---@type table
local root_ = nil

-- 当前值（初始从 GameConfig / audio 读取）
local curSensitivity_ = 0.15
local curMusicVol_ = 0.4
local curSfxVol_ = 0.7

-- 关闭回调
local onClose_ = nil

-- ============================================================================
-- 辅助：创建带标签的滑条行
-- ============================================================================

---@param label string
---@param initVal number 0~1
---@param onChange fun(v: number)
---@param labelId string 用于 FindById 查找数值标签
local function createSliderRow(label, initVal, onChange, labelId)
    local row = UI.Panel {
        id = labelId .. "_row",
        flexDirection = "row",
        alignItems = "center",
        width = "100%",
        marginBottom = 16,
        children = {
            -- 左侧标签
            UI.Label {
                text = label,
                fontSize = 14,
                fontColor = { 200, 200, 220, 220 },
                width = 90,
            },
            -- 滑条
            UI.Slider {
                id = labelId .. "_slider",
                flex = 1,
                height = 28,
                min = 0,
                max = 100,
                value = math.floor(initVal * 100 + 0.5),
                onChange = function(self, v)
                    local normalized = v / 100
                    -- 通过 id 查找同行的数值标签并更新
                    if root_ then
                        local lbl = root_:FindById(labelId)
                        if lbl then
                            lbl:SetText(tostring(math.floor(v + 0.5)))
                        end
                    end
                    if onChange then onChange(normalized) end
                end,
            },
            -- 右侧数值
            UI.Label {
                id = labelId,
                text = tostring(math.floor(initVal * 100 + 0.5)),
                fontSize = 14,
                fontColor = { 200, 200, 220, 220 },
                width = 40,
                textAlign = "right",
            },
        },
    }
    return row
end

-- ============================================================================
-- 辅助：操控模式切换按钮
-- ============================================================================

local MODE_LABELS = { auto = "自动", pc = "PC", mobile = "手游", gamepad = "手柄" }
local modeButtons_ = {}  -- mode -> button widget
local gamepadSensRow_ = nil  -- 手柄灵敏度行（按需显示/隐藏）

---@param label string
---@param mode string "auto"|"pc"|"mobile"|"gamepad"
local function createModeButton(label, mode)
    local isActive = (MobileControls.GetModeSetting() == mode)
    local btn = UI.Button {
        id = "modeBtn_" .. mode,
        text = label,
        fontSize = 13,
        width = 70,
        height = 32,
        marginLeft = 8,
        borderRadius = 6,
        variant = isActive and "primary" or "outline",
        onClick = function(self)
            MobileControls.SetMode(mode)
            -- 更新按钮视觉
            for m, b in pairs(modeButtons_) do
                b.props.variant = (m == mode) and "primary" or "outline"
            end
            -- 手柄灵敏度行：仅手柄模式显示
            if gamepadSensRow_ then
                if mode == "gamepad" then
                    gamepadSensRow_:Show()
                else
                    gamepadSensRow_:Hide()
                end
            end
        end,
    }
    modeButtons_[mode] = btn
    return btn
end

-- ============================================================================
-- 初始化
-- ============================================================================

function SettingsUI.Init()
    -- 读取当前值
    curSensitivity_ = GameConfig.Player.MouseSensitivity or 0.15
    curMusicVol_ = 0.4
    curSfxVol_ = 0.7

    root_ = UI.Panel {
        id = "settingsPanel",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 10, 10, 20, 200 },
        justifyContent = "center",
        alignItems = "center",
        visible = false,
        children = {
            UI.Panel {
                width = 400,
                backgroundColor = { 25, 25, 35, 245 },
                borderRadius = 16,
                borderWidth = 2,
                borderColor = { 180, 160, 120, 180 },
                padding = { 30, 40 },
                alignItems = "center",
                children = {
                    -- 标题
                    UI.Label {
                        text = "设  置",
                        fontSize = 24,
                        fontWeight = "bold",
                        fontColor = { 240, 220, 160, 255 },
                        marginBottom = 24,
                    },
                    -- 分隔线
                    UI.Panel {
                        width = "80%",
                        height = 1,
                        backgroundColor = { 180, 160, 120, 60 },
                        marginBottom = 24,
                    },

                    -- 鼠标灵敏度 (0.01 ~ 0.50)
                    createSliderRow("鼠标灵敏度", curSensitivity_ / 0.5, function(v)
                        local sens = math.max(0.01, v * 0.5)
                        curSensitivity_ = sens
                        GameConfig.Player.MouseSensitivity = sens
                    end, "sensVal"),

                    -- 游戏音乐 (0 ~ 1)
                    createSliderRow("游戏音乐", curMusicVol_, function(v)
                        curMusicVol_ = v
                        audio:SetMasterGain("Music", v)
                    end, "musicVal"),

                    -- 游戏音效 (0 ~ 1)
                    createSliderRow("游戏音效", curSfxVol_, function(v)
                        curSfxVol_ = v
                        audio:SetMasterGain("Effect", v)
                    end, "sfxVal"),

                    -- 分隔线
                    UI.Panel {
                        width = "80%",
                        height = 1,
                        backgroundColor = { 180, 160, 120, 60 },
                        marginTop = 8,
                        marginBottom = 16,
                    },

                    -- 操控模式选择
                    UI.Panel {
                        id = "controlMode_row",
                        flexDirection = "row",
                        alignItems = "center",
                        width = "100%",
                        marginBottom = 16,
                        children = {
                            UI.Label {
                                text = "操控模式",
                                fontSize = 14,
                                fontColor = { 200, 200, 220, 220 },
                                width = 90,
                            },
                            createModeButton("自动", "auto"),
                            createModeButton("PC",   "pc"),
                            createModeButton("手游", "mobile"),
                            createModeButton("手柄", "gamepad"),
                        },
                    },

                    -- 手柄灵敏度（仅手柄模式可见）
                    createSliderRow("手柄灵敏度", (GameConfig.Gamepad.Sensitivity or 1.5) / 3.0, function(v)
                        local sens = math.max(0.5, v * 3.0)
                        GameConfig.Gamepad.Sensitivity = sens
                    end, "gpSensVal"),

                    -- 新手教程开关
                    UI.Panel {
                        id = "tutorialToggle_row",
                        flexDirection = "row",
                        alignItems = "center",
                        width = "100%",
                        marginBottom = 16,
                        children = {
                            UI.Label {
                                text = "新手教程",
                                fontSize = 14,
                                fontColor = { 200, 200, 220, 220 },
                                width = 90,
                            },
                            UI.Label {
                                id = "tutorialStatus",
                                text = TutorialUI.IsCompleted() and "已完成" or "未完成",
                                fontSize = 13,
                                fontColor = TutorialUI.IsCompleted()
                                    and { 120, 200, 120, 220 }
                                    or  { 200, 180, 120, 220 },
                                flex = 1,
                            },
                            UI.Button {
                                id = "tutorialResetBtn",
                                text = "重置教程",
                                fontSize = 13,
                                width = 90,
                                height = 32,
                                borderRadius = 6,
                                variant = "outline",
                                onClick = function(self)
                                    TutorialUI.ResetCompleted()
                                    -- 更新状态文本
                                    if root_ then
                                        local lbl = root_:FindById("tutorialStatus")
                                        if lbl then
                                            lbl:SetText("已重置")
                                            lbl:SetStyle({ fontColor = { 255, 180, 80, 255 } })
                                        end
                                    end
                                    UI.Toast.Show("新手教程已重置，下次新建存档时将重新触发", { variant = "success", duration = 2.5 })
                                end,
                            },
                        },
                    },

                    -- 底部间距
                    UI.Panel { height = 12 },

                    -- 返回按钮
                    UI.Button {
                        text = "返  回",
                        fontSize = 16,
                        width = 160,
                        height = 44,
                        variant = "outline",
                        borderRadius = 8,
                        onClick = function(self)
                            SettingsUI.Hide()
                        end,
                    },
                },
            },
        },
    }

    -- 缓存手柄灵敏度行引用，根据当前模式显示/隐藏
    gamepadSensRow_ = root_:FindById("gpSensVal_row")
    if gamepadSensRow_ then
        if MobileControls.GetModeSetting() ~= "gamepad" then
            gamepadSensRow_:Hide()
        end
    end

    print("[SettingsUI] 初始化完成")
    return root_
end

-- ============================================================================
-- 显示 / 隐藏
-- ============================================================================

function SettingsUI.Show()
    if root_ then root_:Show() end
end

function SettingsUI.Hide()
    if root_ then root_:Hide() end
    if onClose_ then onClose_() end
end

function SettingsUI.IsVisible()
    if root_ then return root_:IsVisible() end
    return false
end

---@param cb function
function SettingsUI.OnClose(cb)
    onClose_ = cb
end

function SettingsUI.GetRoot()
    return root_
end

return SettingsUI
