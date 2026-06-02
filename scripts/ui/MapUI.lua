-- ============================================================================
-- MapUI.lua — 简易地图界面（M键打开）
-- 俯视图显示大世界布局、玩家位置、区域标记
-- 适配 800×800 米大地图
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local FirstPersonController = require("core.FirstPersonController")
local UI = require("urhox-libs/UI")

local MapUI = {}

-- 状态
local isActive_ = false
local mapRoot_ = nil
local playerDot_ = nil
local fpController_ = nil

-- 地图配置（800m 世界映射到 360px 地图面板）
local MAP_SIZE = 360       -- 地图面板像素尺寸
local MAP_CENTER = 180     -- 面板中心
local MAP_SCALE = 0.42     -- 世界坐标到像素: 360 / 800 ≈ 0.45，稍小留边距

-- 地标数据 — 村庄核心
local LANDMARKS = {
    { name = "村长家",     x = -10, z = 5,   color = { 200, 180, 140 }, size = 6 },
    { name = "阿阳家",     x = 10,  z = 3,   color = { 220, 200, 120 }, size = 5 },
    { name = "七七住处",   x = -8,  z = -6,  color = { 220, 180, 200 }, size = 5 },
    { name = "嗡摩佬铺子", x = 8,   z = -5,  color = { 220, 160, 100 }, size = 5 },
    { name = "庙宇",       x = 0,   z = 32,  color = { 220, 200, 140 }, size = 7 },
    { name = "石桥",       x = 0,   z = -12, color = { 160, 140, 120 }, size = 4 },
    { name = "水井",       x = 2,   z = 6,   color = { 140, 180, 220 }, size = 3 },
}

-- 区域标记 — 大世界特色区域
local ZONES = {
    { name = "密林",     x = 200,  z = 200,  color = { 80, 140, 60, 120 } },
    { name = "岩谷",     x = -210, z = 210,  color = { 140, 130, 110, 120 } },
    { name = "废墟",     x = -200, z = -200, color = { 130, 120, 100, 120 } },
    { name = "乱石滩",   x = 200,  z = -200, color = { 150, 130, 100, 120 } },
    { name = "农田",     x = 80,   z = 70,   color = { 120, 160, 80, 120 } },
}

-- ============================================================================
-- 世界坐标 → 地图像素坐标
-- ============================================================================

local function worldToMap(worldX, worldZ)
    local mapX = MAP_CENTER + worldX * MAP_SCALE
    local mapY = MAP_CENTER - worldZ * MAP_SCALE
    return mapX, mapY
end

-- ============================================================================
-- 创建地标标记
-- ============================================================================

local function createLandmark(cfg)
    local mx, my = worldToMap(cfg.x, cfg.z)
    local dotSize = cfg.size or 6

    return UI.Panel {
        position = "absolute",
        left = math.floor(mx) - dotSize / 2,
        top = math.floor(my) - dotSize / 2,
        children = {
            UI.Panel {
                width = dotSize,
                height = dotSize,
                borderRadius = dotSize / 2,
                backgroundColor = { cfg.color[1], cfg.color[2], cfg.color[3], 200 },
                borderWidth = 1,
                borderColor = { 255, 255, 255, 100 },
            },
            UI.Label {
                text = cfg.name,
                fontSize = 8,
                fontColor = { cfg.color[1], cfg.color[2], cfg.color[3], 180 },
                marginTop = 1,
                textAlign = "center",
            },
        },
    }
end

-- ============================================================================
-- 创建区域标签
-- ============================================================================

local function createZoneLabel(zone)
    local mx, my = worldToMap(zone.x, zone.z)

    return UI.Label {
        position = "absolute",
        left = math.floor(mx) - 20,
        top = math.floor(my) - 6,
        text = zone.name,
        fontSize = 10,
        fontColor = zone.color,
        textAlign = "center",
    }
end

-- ============================================================================
-- 初始化
-- ============================================================================

function MapUI.Init()
    local mapChildren = {}

    -- 区域底色圆圈（标示不同区域范围）
    for _, zone in ipairs(ZONES) do
        local mx, my = worldToMap(zone.x, zone.z)
        table.insert(mapChildren, UI.Panel {
            position = "absolute",
            left = math.floor(mx) - 25,
            top = math.floor(my) - 25,
            width = 50,
            height = 50,
            borderRadius = 25,
            backgroundColor = { zone.color[1], zone.color[2], zone.color[3], 40 },
        })
    end

    -- 道路标记
    local roads = {
        -- 主干道 南北向 (贯穿地图)
        UI.Panel {
            position = "absolute",
            left = MAP_CENTER - 1,
            top = MAP_CENTER - math.floor(150 * MAP_SCALE),
            width = 3,
            height = math.floor(300 * MAP_SCALE),
            backgroundColor = { 180, 150, 100, 50 },
        },
        -- 东西支路
        UI.Panel {
            position = "absolute",
            left = MAP_CENTER - math.floor(100 * MAP_SCALE),
            top = math.floor(MAP_CENTER - 8 * MAP_SCALE) - 1,
            width = math.floor(200 * MAP_SCALE),
            height = 3,
            backgroundColor = { 180, 150, 100, 50 },
        },
    }
    for _, road in ipairs(roads) do
        table.insert(mapChildren, road)
    end

    -- 河流
    local riverMx, riverMy = worldToMap(0, -12)
    table.insert(mapChildren, UI.Panel {
        position = "absolute",
        left = MAP_CENTER - math.floor(100 * MAP_SCALE),
        top = math.floor(riverMy) - 1,
        width = math.floor(200 * MAP_SCALE),
        height = 2,
        backgroundColor = { 80, 140, 200, 100 },
    })

    -- 区域标签
    for _, zone in ipairs(ZONES) do
        table.insert(mapChildren, createZoneLabel(zone))
    end

    -- 地标
    for _, cfg in ipairs(LANDMARKS) do
        table.insert(mapChildren, createLandmark(cfg))
    end

    -- 边界框
    local bdist = 395 * MAP_SCALE
    table.insert(mapChildren, UI.Panel {
        position = "absolute",
        left = math.floor(MAP_CENTER - bdist),
        top = math.floor(MAP_CENTER - bdist),
        width = math.floor(bdist * 2),
        height = math.floor(bdist * 2),
        borderWidth = 1,
        borderColor = { 120, 100, 180, 100 },
        borderRadius = 4,
    })

    -- 玩家标记
    playerDot_ = UI.Panel {
        id = "playerDot",
        position = "absolute",
        left = MAP_CENTER - 5,
        top = MAP_CENTER - 5,
        width = 10,
        height = 10,
        borderRadius = 5,
        backgroundColor = { 80, 200, 255, 255 },
        borderWidth = 2,
        borderColor = { 255, 255, 255, 220 },
    }
    table.insert(mapChildren, playerDot_)

    mapRoot_ = UI.Panel {
        id = "mapPanel",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 10, 10, 20, 200 },
        justifyContent = "center",
        alignItems = "center",
        visible = false,
        children = {
            UI.Panel {
                width = MAP_SIZE + 40,
                height = MAP_SIZE + 60,
                backgroundColor = { 20, 30, 18, 240 },
                borderRadius = 12,
                borderWidth = 2,
                borderColor = { 140, 120, 80, 180 },
                alignItems = "center",
                children = {
                    -- 标题
                    UI.Label {
                        text = "大世界地图",
                        fontSize = 16,
                        fontWeight = "bold",
                        fontColor = { 240, 220, 160, 220 },
                        marginTop = 10,
                        marginBottom = 6,
                    },
                    -- 地图内容区
                    UI.Panel {
                        width = MAP_SIZE,
                        height = MAP_SIZE,
                        backgroundColor = { 30, 45, 25, 230 },
                        borderRadius = 6,
                        overflow = "hidden",
                        children = mapChildren,
                    },
                    -- 底部提示
                    UI.Label {
                        text = "按 M 或 ESC 关闭 | 800×800m",
                        fontSize = 9,
                        fontColor = { 150, 150, 150, 140 },
                        marginTop = 6,
                    },
                },
            },
        },
    }

    print("[MapUI] 初始化完成 (大地图模式)")
    return mapRoot_
end

-- ============================================================================
-- 设置控制器引用
-- ============================================================================

---@param controller table
function MapUI.SetController(controller)
    fpController_ = controller
end

-- ============================================================================
-- 更新玩家位置标记
-- ============================================================================

local function updatePlayerDot()
    if not playerDot_ or not fpController_ then return end
    local pos = fpController_:GetPosition()
    local mx, my = worldToMap(pos.x, pos.z)
    playerDot_:SetStyle({ left = math.floor(mx) - 5, top = math.floor(my) - 5 })
end

-- ============================================================================
-- 显示/隐藏
-- ============================================================================

function MapUI.Show()
    if isActive_ then return end
    isActive_ = true
    GameManager.SetState(GameConfig.States.MAP)
    FirstPersonController.SetMouseAbsolute()
    updatePlayerDot()
    if mapRoot_ then mapRoot_:Show() end
end

function MapUI.Hide()
    if not isActive_ then return end
    isActive_ = false
    GameManager.SetState(GameConfig.States.PLAYING)
    FirstPersonController.SetMouseRelative()
    if mapRoot_ then mapRoot_:Hide() end
end

function MapUI.Toggle()
    if isActive_ then MapUI.Hide() else MapUI.Show() end
end

-- ============================================================================
-- 每帧更新
-- ============================================================================

function MapUI.Update(dt)
    if not isActive_ then return end
    if input:GetKeyPress(KEY_M) or input:GetKeyPress(KEY_ESCAPE) then
        MapUI.Hide()
    end
end

---@return boolean
function MapUI.IsActive()
    return isActive_
end

---@return table
function MapUI.GetRoot()
    return mapRoot_
end

return MapUI
