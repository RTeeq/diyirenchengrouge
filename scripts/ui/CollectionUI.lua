-- ============================================================================
-- CollectionUI.lua — 图鉴界面（Tab键打开）
-- 展示已收集的物品，未收集的显示为"???"
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local QuestData = require("data.QuestData")
local FirstPersonController = require("core.FirstPersonController")
local UI = require("urhox-libs/UI")
local UIHelper = require("ui.UIHelper")

local CollectionUI = {}

-- 状态
local isActive_ = false
local collectionRoot_ = nil

-- 所有物品ID列表（保证顺序）
local ALL_ITEMS = {
    GameConfig.Items.FIRE_DRAGON_CARD,
    GameConfig.Items.PEACE_JADE,
    GameConfig.Items.SECRET_KEY,
    GameConfig.Items.BAGUA_MIRROR,
    GameConfig.Items.EXORCISM_TALISMAN,
    GameConfig.Items.MYSTERY_FRAGMENT,
    GameConfig.Items.OPENED_SCROLL,
    GameConfig.Items.SEALED_SCROLL,
    GameConfig.Items.SECRET_BOX,
    GameConfig.Items.HOLY_WATER,
}

-- ============================================================================
-- 构建物品卡片
-- ============================================================================

local function createItemCard(itemId, index)
    local hasItem = GameManager.HasItem(itemId)
    local info = QuestData.GetItemInfo(itemId)

    local name = hasItem and (info and info.name or itemId) or "???"
    local desc = hasItem and (info and info.desc or "") or "尚未发现"
    local bgColor = hasItem
        and { 45, 55, 40, 240 }
        or { 40, 40, 50, 200 }
    local borderCol = hasItem
        and { 120, 180, 100, 200 }
        or { 80, 80, 90, 150 }
    local nameColor = hasItem
        and { 220, 240, 180, 255 }
        or { 120, 120, 130, 200 }

    return UI.Panel {
        width = "45%",
        minHeight = 70,
        margin = 6,
        padding = { 10, 12 },
        backgroundColor = bgColor,
        borderRadius = 8,
        borderWidth = 1,
        borderColor = borderCol,
        children = {
            UI.Label {
                text = index .. ". " .. name,
                fontSize = 14,
                fontWeight = hasItem and "bold" or "normal",
                fontColor = nameColor,
                marginBottom = 4,
            },
            UI.Label {
                text = desc,
                fontSize = 11,
                fontColor = { 180, 180, 180, 180 },
                lineHeight = 1.4,
            },
        },
    }
end

-- ============================================================================
-- 初始化
-- ============================================================================

function CollectionUI.Init()
    collectionRoot_ = UI.Panel {
        id = "collectionPanel",
        position = "absolute",
        top = 0,
        left = 0,
        right = 0,
        bottom = 0,
        backgroundColor = { 10, 10, 20, 200 },
        justifyContent = "center",
        alignItems = "center",
        visible = false,
        children = {
            UI.Panel {
                width = "80%",
                maxWidth = 600,
                maxHeight = "85%",
                backgroundColor = { 25, 25, 35, 245 },
                borderRadius = 16,
                borderWidth = 2,
                borderColor = { 180, 160, 120, 180 },
                padding = 20,
                children = {
                    -- 标题栏
                    UI.Panel {
                        flexDirection = "row",
                        justifyContent = "space-between",
                        alignItems = "center",
                        marginBottom = 16,
                        children = {
                            UI.Label {
                                text = "物品图鉴",
                                fontSize = 20,
                                fontWeight = "bold",
                                fontColor = { 240, 220, 160, 255 },
                            },
                            UI.Label {
                                id = "collectionCount",
                                text = "0/10",
                                fontSize = 14,
                                fontColor = { 180, 180, 180, 200 },
                            },
                        },
                    },
                    -- 分隔线
                    UI.Panel {
                        width = "100%",
                        height = 1,
                        backgroundColor = { 180, 160, 120, 80 },
                        marginBottom = 12,
                    },
                    -- 物品列表（网格）
                    UI.ScrollView {
                        id = "collectionScroll",
                        flexGrow = 1,
                        width = "100%",
                        children = {
                            UI.Panel {
                                id = "collectionGrid",
                                flexDirection = "row",
                                flexWrap = "wrap",
                                justifyContent = "center",
                            },
                        },
                    },
                    -- 底部提示
                    UI.Panel {
                        marginTop = 12,
                        alignItems = "center",
                        children = {
                            UI.Label {
                                text = "按 Tab 或 ESC 关闭",
                                fontSize = 11,
                                fontColor = { 150, 150, 150, 140 },
                            },
                        },
                    },
                },
            },
        },
    }

    print("[CollectionUI] 初始化完成")
    return collectionRoot_
end

-- ============================================================================
-- 刷新内容
-- ============================================================================

function CollectionUI.Refresh()
    if not collectionRoot_ then return end

    local grid = collectionRoot_:FindById("collectionGrid")
    if not grid then return end

    -- 清空现有内容
    UIHelper.DestroyChildren(grid)

    -- 重新构建物品卡片
    for i, itemId in ipairs(ALL_ITEMS) do
        local card = createItemCard(itemId, i)
        grid:AddChild(card)
    end

    -- 更新计数
    local countLabel = collectionRoot_:FindById("collectionCount")
    if countLabel then
        countLabel:SetText(GameManager.GetItemCount() .. "/10")
    end
end

-- ============================================================================
-- 显示/隐藏
-- ============================================================================

function CollectionUI.Show()
    if isActive_ then return end
    isActive_ = true

    GameManager.SetState(GameConfig.States.COLLECTION)
    FirstPersonController.SetMouseAbsolute()

    CollectionUI.Refresh()

    if collectionRoot_ then
        collectionRoot_:Show()
    end
end

function CollectionUI.Hide()
    if not isActive_ then return end
    isActive_ = false

    GameManager.SetState(GameConfig.States.PLAYING)
    FirstPersonController.SetMouseRelative()

    if collectionRoot_ then
        collectionRoot_:Hide()
    end
end

function CollectionUI.Toggle()
    if isActive_ then
        CollectionUI.Hide()
    else
        CollectionUI.Show()
    end
end

-- ============================================================================
-- 每帧更新（输入检测）
-- ============================================================================

function CollectionUI.Update(dt)
    if not isActive_ then return end

    if input:GetKeyPress(KEY_TAB) or input:GetKeyPress(KEY_ESCAPE) then
        CollectionUI.Hide()
    end
end

---@return boolean
function CollectionUI.IsActive()
    return isActive_
end

---@return table
function CollectionUI.GetRoot()
    return collectionRoot_
end

return CollectionUI
