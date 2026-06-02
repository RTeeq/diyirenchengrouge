-- ============================================================================
-- MenuUI.lua — 暂停菜单
-- ESC 打开/关闭。包含：继续游戏、设置、脱离卡死、返回主页、退出游戏
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local FirstPersonController = require("core.FirstPersonController")
local SettingsUI = require("ui.SettingsUI")
local UI = require("urhox-libs/UI")

local MenuUI = {}

-- 状态
local isPaused_ = false
local pauseRoot_ = nil

-- 回调
local onResume_ = nil
local onNewGame_ = nil
local onReturnHome_ = nil
local onExitGame_ = nil
local onUnstuck_ = nil

-- ============================================================================
-- 创建按钮
-- ============================================================================

local function createMenuButton(text, onClick)
    return UI.Button {
        text = text,
        fontSize = 16,
        width = 220,
        height = 44,
        marginBottom = 12,
        variant = "outline",
        borderRadius = 8,
        onClick = onClick,
    }
end

-- ============================================================================
-- 初始化暂停菜单
-- ============================================================================

function MenuUI.Init()
    pauseRoot_ = UI.Panel {
        id = "pauseMenu",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 10, 10, 20, 180 },
        justifyContent = "center",
        alignItems = "center",
        visible = false,
        children = {
            UI.Panel {
                width = 320,
                backgroundColor = { 25, 25, 35, 240 },
                borderRadius = 16,
                borderWidth = 2,
                borderColor = { 180, 160, 120, 180 },
                padding = { 30, 40 },
                alignItems = "center",
                children = {
                    -- 标题
                    UI.Label {
                        text = "暂停",
                        fontSize = 24,
                        fontWeight = "bold",
                        fontColor = { 240, 220, 160, 255 },
                        marginBottom = 8,
                    },
                    UI.Panel { height = 16 },
                    -- 分隔线
                    UI.Panel {
                        width = "80%",
                        height = 1,
                        backgroundColor = { 180, 160, 120, 60 },
                        marginBottom = 20,
                    },
                    -- 继续游戏
                    createMenuButton("继续游戏", function(self)
                        MenuUI.Resume()
                    end),
                    -- 重新开始
                    createMenuButton("重新开始", function(self)
                        if onNewGame_ then onNewGame_() end
                        MenuUI.Resume()
                    end),
                    -- 设置
                    createMenuButton("设    置", function(self)
                        SettingsUI.Show()
                    end),
                    -- 脱离卡死
                    createMenuButton("脱离卡死", function(self)
                        if onUnstuck_ then onUnstuck_() end
                        MenuUI.Resume()
                    end),

                    -- 底部分隔线
                    UI.Panel {
                        width = "80%",
                        height = 1,
                        backgroundColor = { 180, 160, 120, 40 },
                        marginTop = 4,
                        marginBottom = 16,
                    },

                    -- 返回主页
                    createMenuButton("返回主页", function(self)
                        if onReturnHome_ then onReturnHome_() end
                    end),

                    -- 底部提示
                    UI.Panel {
                        marginTop = 8,
                        children = {
                            UI.Label {
                                text = "按 ESC 继续",
                                fontSize = 11,
                                fontColor = { 150, 150, 150, 120 },
                            },
                        },
                    },
                },
            },
        },
    }

    print("[MenuUI] 暂停菜单初始化完成")
    return pauseRoot_
end

-- ============================================================================
-- 回调设置
-- ============================================================================

---@param callback function
function MenuUI.OnResume(callback)
    onResume_ = callback
end

---@param callback function
function MenuUI.OnNewGame(callback)
    onNewGame_ = callback
end

---@param callback function
function MenuUI.OnReturnHome(callback)
    onReturnHome_ = callback
end

---@param callback function
function MenuUI.OnExitGame(callback)
    onExitGame_ = callback
end

---@param callback function
function MenuUI.OnUnstuck(callback)
    onUnstuck_ = callback
end

-- ============================================================================
-- 暂停/恢复
-- ============================================================================

function MenuUI.Pause()
    if isPaused_ then return end
    isPaused_ = true

    GameManager.SetState(GameConfig.States.PAUSED)
    FirstPersonController.SetMouseAbsolute()

    if pauseRoot_ then
        pauseRoot_:Show()
    end
end

function MenuUI.Resume()
    if not isPaused_ then return end
    isPaused_ = false

    -- 同时关闭设置面板（如果打开着）
    if SettingsUI.IsVisible() then
        SettingsUI.Hide()
    end

    GameManager.SetState(GameConfig.States.PLAYING)
    FirstPersonController.SetMouseRelative()

    if pauseRoot_ then
        pauseRoot_:Hide()
    end

    if onResume_ then
        onResume_()
    end
end

function MenuUI.Toggle()
    if isPaused_ then
        MenuUI.Resume()
    else
        MenuUI.Pause()
    end
end

-- ============================================================================
-- 每帧更新
-- ============================================================================

function MenuUI.Update(dt)
    if not isPaused_ then return end

    if input:GetKeyPress(KEY_ESCAPE) then
        -- 如果设置面板打开，先关设置；否则关暂停菜单
        if SettingsUI.IsVisible() then
            SettingsUI.Hide()
        else
            MenuUI.Resume()
        end
    end
end

---@return boolean
function MenuUI.IsPaused()
    return isPaused_
end

---@return table
function MenuUI.GetRoot()
    return pauseRoot_
end

return MenuUI
