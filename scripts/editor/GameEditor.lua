-- ============================================================================
-- GameEditor.lua — 游戏内置开发者面板
-- 按 P 键调出右侧 Drawer 面板，仅包含开发者调试工具
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local FirstPersonController = require("core.FirstPersonController")
local EditorDevTab = require("editor.EditorDevTab")
local UI = require("urhox-libs/UI")

local GameEditor = {}

-- 状态
local isOpen_ = false
local isInitialized_ = false   -- 延迟初始化标记
---@type Scene
local scene_ = nil
local fpController_ = nil
local uiRoot_ = nil            -- 保存 uiRoot 引用用于延迟初始化

-- UI 引用
local drawerPanel_ = nil

-- ============================================================================
-- 颜色转换工具（UI 0-255 <-> 引擎 0.0-1.0）
-- ============================================================================

--- UI RGBA (0-255) -> 引擎 Color (0.0-1.0)
---@param rgba table {r, g, b, a}
---@return Color
function GameEditor.RGBAToColor(rgba)
    return Color(
        (rgba[1] or 255) / 255,
        (rgba[2] or 255) / 255,
        (rgba[3] or 255) / 255,
        (rgba[4] or 255) / 255
    )
end

--- 引擎 Color (0.0-1.0) -> UI RGBA (0-255)
---@param color Color
---@return table
function GameEditor.ColorToRGBA(color)
    return {
        math.floor(color.r * 255 + 0.5),
        math.floor(color.g * 255 + 0.5),
        math.floor(color.b * 255 + 0.5),
        math.floor(color.a * 255 + 0.5),
    }
end

-- ============================================================================
-- 创建开发者面板 UI
-- ============================================================================

local HEADER_BG = { 30, 30, 40, 255 }

local function createEditorUI()
    local devContent = EditorDevTab.CreateDevPanel()

    -- ── 面板标题栏 ──
    local panelHeader = UI.Panel {
        flexDirection = "row",
        justifyContent = "space-between",
        alignItems = "center",
        paddingHorizontal = 10,
        paddingVertical = 6,
        backgroundColor = HEADER_BG,
        borderBottomWidth = 1,
        borderColor = { 45, 45, 55, 255 },
        children = {
            UI.Label {
                text = "🔧 开发者",
                fontSize = 12,
                fontWeight = "bold",
                fontColor = { 190, 190, 200, 255 },
            },
            UI.Button {
                text = "✕",
                fontSize = 12,
                width = 28, height = 24,
                paddingHorizontal = 0,
                paddingVertical = 0,
                backgroundColor = { 70, 50, 50, 255 },
                hoverBackgroundColor = { 100, 60, 60, 255 },
                textColor = { 200, 180, 180, 255 },
                borderRadius = 4,
                onClick = function(self)
                    GameEditor.Close()
                end,
            },
        },
    }

    -- ── 全屏面板 ──
    drawerPanel_ = UI.Panel {
        id = "editorDrawer",
        position = "absolute",
        left = 0, right = 0, top = 0, bottom = 0,
        backgroundColor = { 18, 18, 24, 240 },
        visible = false,
        children = {
            panelHeader,
            devContent,
        },
    }

    return drawerPanel_
end

-- ============================================================================
-- 公开接口
-- ============================================================================

--- 初始化编辑器（延迟模式：仅保存引用，不创建 UI）
---@param scene Scene
---@param uiRoot table UI 根面板
---@param controller table FirstPersonController 实例
function GameEditor.Init(scene, uiRoot, controller)
    scene_ = scene
    fpController_ = controller
    uiRoot_ = uiRoot
    -- 不再立即创建 UI，延迟到首次 Open() 时
    print("[GameEditor] 开发者面板已注册（延迟初始化）")
end

--- 真正创建编辑器 UI（仅在首次打开时调用一次）
local function ensureInitialized()
    if isInitialized_ then return end
    isInitialized_ = true

    -- 初始化开发者面板数据
    EditorDevTab.Init(scene_, fpController_)

    -- 创建 UI
    local editorUI = createEditorUI()

    -- 将编辑器面板添加到 UI 根
    if uiRoot_ then
        uiRoot_:AddChild(editorUI)
    end

    print("[GameEditor] 开发者面板 UI 已创建（首次打开）")
end

--- 打开编辑器
function GameEditor.Open()
    if isOpen_ then return end

    -- 首次打开时才创建 UI（节省 ~337 个 Yoga 节点）
    ensureInitialized()

    isOpen_ = true

    GameManager.SetState(GameConfig.States.EDITOR)
    FirstPersonController.SetMouseAbsolute()

    if drawerPanel_ then
        drawerPanel_:Show()
    end

    -- 刷新数据
    EditorDevTab.Refresh()

    print("[GameEditor] 开发者面板已打开")
end

--- 关闭编辑器
function GameEditor.Close()
    if not isOpen_ then return end
    isOpen_ = false

    if drawerPanel_ then
        drawerPanel_:Hide()
    end

    GameManager.SetState(GameConfig.States.PLAYING)
    FirstPersonController.SetMouseRelative()

    print("[GameEditor] 开发者面板已关闭")
end

--- 切换编辑器
function GameEditor.Toggle()
    if isOpen_ then
        GameEditor.Close()
    else
        GameEditor.Open()
    end
end

--- 每帧更新
---@param dt number
function GameEditor.Update(dt)
    if not isOpen_ then return end

    -- P 键关闭
    if input:GetKeyPress(KEY_P) then
        GameEditor.Close()
        return
    end

    EditorDevTab.Update(dt)
end

--- 编辑器是否打开
---@return boolean
function GameEditor.IsOpen()
    return isOpen_
end

--- 获取场景引用
---@return Scene
function GameEditor.GetScene()
    return scene_
end

return GameEditor
