-- ============================================================================
-- CharacterPanelUI.lua — 角色面板（Tab键打开）
-- 仓库网格浏览、装备更换（拖拽）、词条查看，分武器/装备/道具三个标签页
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local FirstPersonController = require("core.FirstPersonController")
local InventorySystem = require("systems.InventorySystem")
local RarityData = require("data.RarityData")
local AffixSystem = require("systems.AffixSystem")
local AffixDatabase = require("data.AffixDatabase")
local EquipmentSystem = require("combat.EquipmentSystem")
local AwakeningSystem = require("systems.AwakeningSystem")
local UI = require("urhox-libs/UI")
local UIHelper = require("ui.UIHelper")

local CharacterPanelUI = {}

-- 状态
local isActive_ = false
local panelRoot_ = nil
local gridContainer_ = nil    -- 当前标签页的物品网格容器
local detailPanel_ = nil       -- 右侧详情面板
local equipSlotsPanel_ = nil   -- 装备槽面板
local awakeningPanel_ = nil    -- 觉醒面板
local currentTab_ = "weapon"   -- 当前标签页
local selectedItem_ = nil      -- 当前选中的物品（用于详情展示）

-- 分页相关
local ITEMS_PER_PAGE = 20
local currentPage_ = 1

-- 拖拽相关
local dragContext_ = nil       -- DragDropContext 实例
local equipSlotWidgets_ = {}   -- 装备槽 ItemSlot 引用 { [slotKey] = ItemSlot }
local gridSlotWidgets_ = {}    -- 网格物品格 ItemSlot 引用 { [index] = ItemSlot }

-- 网格列数
local GRID_COLS = 5
local GRID_CELL_SIZE = 56

-- 分类显示名映射
local TAB_NAMES = {
    weapon    = "武器",
    equipment = "装备",
    item      = "道具",
}

-- ============================================================================
-- 物品名称获取
-- ============================================================================

local function getItemDisplayName(item)
    if item.category == "weapon" then
        local w = GameConfig.Weapons[item.baseId]
        return w and w.name or item.baseId
    elseif item.category == "equipment" then
        local eq = GameConfig.Equipment[item.baseId]
        return eq and eq.name or item.baseId
    else
        return item.baseId
    end
end

local function getItemIcon(item)
    if item.category == "weapon" then
        local w = GameConfig.Weapons[item.baseId]
        return w and w.icon or "?"
    elseif item.category == "equipment" then
        local eq = GameConfig.Equipment[item.baseId]
        return eq and eq.icon or "?"
    else
        return "📦"
    end
end

local function getItemDesc(item)
    if item.category == "equipment" then
        local eq = GameConfig.Equipment[item.baseId]
        return eq and eq.desc or ""
    elseif item.category == "weapon" then
        local w = GameConfig.Weapons[item.baseId]
        return w and (w.skill or "") or ""
    end
    return ""
end

-- ============================================================================
-- 将游戏物品转换为 ItemSlot 兼容格式
-- ============================================================================

--- 把 InventorySystem 的 item 转为 ItemSlot 需要的 { id, name, icon, type, ... } 格式
local function toSlotItem(item)
    if not item then return nil end
    return {
        id = item.uid,
        uid = item.uid,
        name = getItemDisplayName(item),
        icon = getItemIcon(item),
        type = item.category,  -- "weapon" / "equipment" / "item"
        -- 保留原始数据，方便回调中取出完整信息
        _raw = item,
    }
end

-- ============================================================================
-- 详情面板
-- ============================================================================

local function showDetail(item)
    if not detailPanel_ then return end
    UIHelper.DestroyChildren(detailPanel_)

    if not item then
        selectedItem_ = nil
        detailPanel_:AddChild(UI.Label {
            text = "选择一个物品查看详情",
            fontSize = 13,
            fontColor = { 140, 140, 150, 180 },
        })
        return
    end

    selectedItem_ = item
    local clr = RarityData.GetRarityColor(item.rarity or 1)
    local rarityName = RarityData.GetRarityName(item.rarity or 1)
    local name = getItemDisplayName(item)
    local icon = getItemIcon(item)
    local desc = getItemDesc(item)

    -- 图标 + 名称
    detailPanel_:AddChild(UI.Label {
        text = icon .. " " .. name,
        fontSize = 18,
        fontWeight = "bold",
        fontColor = clr,
        marginBottom = 4,
    })

    -- 品级
    detailPanel_:AddChild(UI.Label {
        text = "品级: " .. rarityName,
        fontSize = 13,
        fontColor = clr,
        marginBottom = 6,
    })

    -- 描述
    if desc ~= "" then
        detailPanel_:AddChild(UI.Label {
            text = desc,
            fontSize = 12,
            fontColor = { 200, 200, 200, 200 },
            lineHeight = 1.4,
            marginBottom = 8,
        })
    end

    -- 基础属性（武器展示伤害等）
    if item.category == "weapon" then
        local w = GameConfig.Weapons[item.baseId]
        if w then
            local statMult = RarityData.GetTier(item.rarity or 1).statMult
            local lines = {}
            if w.damage then table.insert(lines, "伤害: " .. math.floor(w.damage * statMult)) end
            if w.cooldown then table.insert(lines, "冷却: " .. string.format("%.1fs", w.cooldown)) end
            if w.range then table.insert(lines, "范围: " .. string.format("%.1fm", w.range)) end
            for _, line in ipairs(lines) do
                detailPanel_:AddChild(UI.Label {
                    text = line,
                    fontSize = 12,
                    fontColor = { 180, 200, 220, 220 },
                    marginBottom = 2,
                })
            end
        end
    elseif item.category == "equipment" then
        local eq = GameConfig.Equipment[item.baseId]
        if eq and eq.passive then
            detailPanel_:AddChild(UI.Label {
                text = "-- 被动属性 --",
                fontSize = 11,
                fontColor = { 150, 170, 200, 180 },
                marginTop = 4,
                marginBottom = 2,
            })
            local passiveNames = {
                maxHP = "生命", damagePct = "伤害%", cooldownPct = "冷却缩减%",
                atkSpdPct = "攻速%", moveSpdPct = "移速%", rangePct = "范围%",
            }
            for stat, val in pairs(eq.passive) do
                local sn = passiveNames[stat] or stat
                detailPanel_:AddChild(UI.Label {
                    text = "+" .. val .. " " .. sn,
                    fontSize = 12,
                    fontColor = { 130, 200, 130, 220 },
                    marginBottom = 1,
                })
            end
        end
        if eq and eq.proc then
            detailPanel_:AddChild(UI.Label {
                text = "触发: " .. (eq.proc.type or "?") .. " (" .. math.floor((eq.proc.chance or 0) * 100) .. "%)",
                fontSize = 11,
                fontColor = { 255, 200, 100, 200 },
                marginTop = 4,
            })
        end
    end

    -- 词条
    local maxSlots = item.maxSlots or AffixSystem.DEFAULT_MAX_SLOTS
    local affixCount = item.affixes and #item.affixes or 0
    if affixCount > 0 then
        detailPanel_:AddChild(UI.Panel {
            width = "100%", height = 1,
            backgroundColor = { 100, 100, 100, 80 },
            marginTop = 8, marginBottom = 6,
        })
        detailPanel_:AddChild(UI.Label {
            text = "词条 (" .. affixCount .. "/" .. maxSlots .. ")",
            fontSize = 12,
            fontWeight = "bold",
            fontColor = { 255, 220, 100, 255 },
            marginBottom = 4,
        })
        for _, affix in ipairs(item.affixes) do
            local qColor = AffixDatabase.GetQualityColor(affix.tier or 1)
            local qName = AffixDatabase.GetQualityName(affix.tier or 1)
            detailPanel_:AddChild(UI.Label {
                text = "[" .. qName .. "] " .. RarityData.FormatAffix(affix),
                fontSize = 11,
                fontColor = qColor,
                marginBottom = 2,
            })
        end
    elseif maxSlots > 0 then
        detailPanel_:AddChild(UI.Panel {
            width = "100%", height = 1,
            backgroundColor = { 100, 100, 100, 80 },
            marginTop = 8, marginBottom = 6,
        })
        detailPanel_:AddChild(UI.Label {
            text = "词条 (0/" .. maxSlots .. ")",
            fontSize = 12,
            fontColor = { 140, 140, 150, 160 },
            marginBottom = 4,
        })
    end

    -- 操作按钮（所有类别都支持装备/卸下）
    local isEquipped = InventorySystem.IsEquipped(item.uid)

    detailPanel_:AddChild(UI.Panel { height = 10 })
    if isEquipped then
        detailPanel_:AddChild(UI.Button {
            text = "卸下",
            variant = "secondary",
            width = "100%",
            onClick = function()
                -- 找到并卸下
                local numSlots = InventorySystem.GetNumEquipSlots()
                for i = 1, numSlots do
                    if InventorySystem.GetEquippedUID(i) == item.uid then
                        InventorySystem.UnequipSlot(i)
                        syncEquipSlots()
                        break
                    end
                end
                refreshGrid()
                refreshEquipSlots()
                showDetail(item)
            end,
        })
    else
        detailPanel_:AddChild(UI.Button {
            text = "装备",
            variant = "primary",
            width = "100%",
            onClick = function()
                local slot = InventorySystem.AutoEquip(item.uid)
                if slot > 0 then
                    syncEquipSlots()
                end
                refreshGrid()
                refreshEquipSlots()
                showDetail(item)
            end,
        })
    end

    -- 分解按钮（铁剑不允许分解）
    if item.baseId ~= "iron_sword" then
        local dismantlePoints = AwakeningSystem.CalcDismantlePoints(item)
        detailPanel_:AddChild(UI.Panel { height = 6 })
        detailPanel_:AddChild(UI.Button {
            text = "分解 (+" .. dismantlePoints .. " 觉醒点)",
            variant = "danger",
            width = "100%",
            onClick = function()
                local pts = InventorySystem.DismantleItem(item.uid)
                syncEquipSlots()
                refreshGrid()
                refreshEquipSlots()
                refreshAwakeningBar()
                showDetail(nil)
                if pts > 0 then
                    print("[CharacterPanelUI] 分解获得 " .. pts .. " 觉醒点")
                end
            end,
        })
    end
end

-- ============================================================================
-- 同步装备槽到 EquipmentSystem（旧系统兼容）
-- ============================================================================

function syncEquipSlots()
    -- 将 InventorySystem 的装备槽同步到 GameManager 和 EquipmentSystem
    local GM = require("core.GameManager")
    local numSlots = InventorySystem.GetNumEquipSlots()
    for i = 1, numSlots do
        local eqItem = InventorySystem.GetEquippedItem(i)
        GM.SetEquipment(i, eqItem and eqItem.baseId or nil)
    end
    -- 同步到 EquipmentSystem（仅 equipment 类物品提供被动加成）
    local es = require("combat.EquipmentSystem")
    local eq = es.GetEquipped()
    for i = 1, numSlots do eq[i] = nil end
    for i = 1, numSlots do
        local eqItem = InventorySystem.GetEquippedItem(i)
        if eqItem and eqItem.category == "equipment" then
            eq[i] = eqItem.baseId
        end
    end
end

-- ============================================================================
-- 拖拽回调
-- ============================================================================

local function onDragStart(itemData, sourceSlot)
    print("[CharacterPanelUI] 拖拽开始: " .. (itemData.name or "?"))
end

local function onDragEnd(itemData, sourceSlot, targetSlot, success)
    if not targetSlot then
        print("[CharacterPanelUI] 拖拽取消 - 无目标")
        return
    end
    if not success then
        print("[CharacterPanelUI] 拖拽失败 - 不可放置")
        return
    end

    local rawItem = itemData._raw
    if not rawItem then return end

    local targetCategory = targetSlot:GetSlotCategory()
    local targetId = targetSlot:GetSlotId()

    if targetCategory == "equipment" then
        -- 拖到装备槽
        local slotIndex = targetId  -- 数字 1~5

        -- 如果已经装备了，先卸下当前装备
        local currentEquipped = InventorySystem.GetEquippedUID(slotIndex)
        if currentEquipped then
            InventorySystem.UnequipSlot(slotIndex)
        end

        -- 如果拖拽物品已在其他槽位装备，先卸下
        if InventorySystem.IsEquipped(rawItem.uid) then
            local numSlots = InventorySystem.GetNumEquipSlots()
            for i = 1, numSlots do
                if InventorySystem.GetEquippedUID(i) == rawItem.uid then
                    InventorySystem.UnequipSlot(i)
                    break
                end
            end
        end

        -- 装备到目标槽位
        InventorySystem.EquipToSlot(rawItem.uid, slotIndex)
        syncEquipSlots()
        print("[CharacterPanelUI] 装备到槽位 " .. slotIndex .. ": " .. (itemData.name or "?"))

    elseif targetCategory == "weapon_slot" then
        -- 拖到武器槽（左手）— 循环切换直到匹配
        local WeaponSystem = require("combat.WeaponSystem")
        if rawItem.category == "weapon" and rawItem.baseId ~= "iron_sword" then
            -- 循环 SwitchWeaponNext 直到左手武器匹配目标
            local maxTries = 20
            for _ = 1, maxTries do
                WeaponSystem.SwitchWeaponNext()
                if WeaponSystem.GetLeftHandWeaponId() == rawItem.baseId then
                    break
                end
            end
            print("[CharacterPanelUI] 切换左手武器: " .. rawItem.baseId)
        end
    end

    -- 刷新所有显示
    refreshGrid()
    refreshEquipSlots()
    showDetail(rawItem)
end

local function onDragCancel(itemData, sourceSlot)
    print("[CharacterPanelUI] 拖拽取消")
end

local function canDrop(itemData, sourceSlot, targetSlot)
    local targetCategory = targetSlot:GetSlotCategory()
    local rawItem = itemData._raw
    if not rawItem then return false end

    if targetCategory == "equipment" then
        -- 所有类型的物品都可以装备到装备槽（weapon/equipment/item）
        return true
    elseif targetCategory == "weapon_slot" then
        -- 只有武器可以拖到武器槽
        return rawItem.category == "weapon"
    end

    return false
end

-- ============================================================================
-- 装备槽显示（用 ItemSlot 组件支持拖入）
-- ============================================================================

-- 槽位图标和标签
local SLOT_ICONS = { "①", "②", "③", "④", "⑤" }

function refreshEquipSlots()
    if not equipSlotsPanel_ then return end
    UIHelper.DestroyChildren(equipSlotsPanel_)
    equipSlotWidgets_ = {}

    local numSlots = InventorySystem.GetNumEquipSlots()

    -- ====== 装备栏标题 + 一行槽位 ======
    local headerRow = UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        marginBottom = 4,
        children = {
            UI.Label {
                text = "装备栏",
                fontSize = 12,
                fontWeight = "bold",
                fontColor = { 220, 200, 140, 255 },
                marginRight = 8,
            },
            UI.Label {
                text = "拖拽装备到此 | 点击查看详情",
                fontSize = 9,
                fontColor = { 100, 160, 220, 120 },
            },
        },
    }
    equipSlotsPanel_:AddChild(headerRow)

    -- 所有槽位一行排列
    local slotsRow = UI.Panel {
        flexDirection = "row",
        gap = 6,
        alignItems = "center",
        flexWrap = "wrap",
    }

    for i = 1, numSlots do
        local eqItem = InventorySystem.GetEquippedItem(i)
        local capturedItem = eqItem  -- capture for closure

        -- 根据装备的物品类型选择图标
        local typeIcon = "📦"
        if eqItem then
            if eqItem.category == "weapon" then typeIcon = "⚔️"
            elseif eqItem.category == "equipment" then typeIcon = "🛡️"
            else typeIcon = "📦" end
        end

        local slot = UI.ItemSlot {
            slotId = i,
            slotCategory = "equipment",
            slotType = "any",
            slotTypeIcon = typeIcon,
            size = 44,
            item = toSlotItem(eqItem),
            dragContext = dragContext_,
            onSlotClick = function(s, slotItemData)
                if capturedItem then showDetail(capturedItem) end
            end,
        }
        equipSlotWidgets_[i] = slot

        local slotWrapper = UI.Panel {
            alignItems = "center",
            children = {
                UI.Label {
                    text = SLOT_ICONS[i] or tostring(i),
                    fontSize = 9,
                    fontColor = { 140, 140, 150, 140 },
                    marginBottom = 1,
                },
                slot,
            },
        }
        slotsRow:AddChild(slotWrapper)
    end

    equipSlotsPanel_:AddChild(slotsRow)
end

-- ============================================================================
-- 觉醒进度
-- ============================================================================

function refreshAwakeningBar()
    if not awakeningPanel_ then return end
    UIHelper.DestroyChildren(awakeningPanel_)

    local level = AwakeningSystem.GetLevel()
    local points = AwakeningSystem.GetPoints()
    local nextPts = AwakeningSystem.GetPointsForNext()
    local clr = AwakeningSystem.GetLevelColor()
    local icon = AwakeningSystem.GetLevelIcon()
    local levelName = AwakeningSystem.GetLevelName()

    -- 等级标签
    local titleText = icon .. " " .. levelName
    if level > 0 then
        titleText = icon .. " " .. levelName .. " Lv." .. level
    end

    awakeningPanel_:AddChild(UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        justifyContent = "space-between",
        width = "100%",
        marginBottom = 4,
        children = {
            UI.Label {
                text = titleText,
                fontSize = 12,
                fontWeight = "bold",
                fontColor = { clr[1], clr[2], clr[3], 255 },
            },
            UI.Label {
                text = nextPts > 0 and (points .. "/" .. nextPts) or "MAX",
                fontSize = 11,
                fontColor = { 180, 180, 190, 200 },
            },
        },
    })

    -- 进度条
    local ratio = 0
    if nextPts > 0 then
        ratio = math.min(points / nextPts, 1.0)
    else
        ratio = 1.0
    end
    local barWidth = math.floor(ratio * 100) .. "%"

    awakeningPanel_:AddChild(UI.Panel {
        width = "100%",
        height = 8,
        backgroundColor = { 40, 40, 50, 200 },
        borderRadius = 4,
        overflow = "hidden",
        children = {
            UI.Panel {
                width = barWidth,
                height = "100%",
                backgroundColor = { clr[1], clr[2], clr[3], 220 },
                borderRadius = 4,
            },
        },
    })

    -- 觉醒按钮
    if AwakeningSystem.CanAwaken() then
        awakeningPanel_:AddChild(UI.Button {
            text = "觉醒! (" .. AwakeningSystem.GetLevelName(level + 1) .. ")",
            variant = "primary",
            width = "100%",
            marginTop = 6,
            onClick = function()
                if AwakeningSystem.DoAwaken() then
                    refreshAwakeningBar()
                    print("[CharacterPanelUI] 觉醒成功! " .. AwakeningSystem.GetLevelName())
                end
            end,
        })
    end
end

-- ============================================================================
-- 物品网格（替代原来的列表视图）
-- ============================================================================

function refreshGrid()
    if not gridContainer_ then return end
    UIHelper.DestroyChildren(gridContainer_)
    gridSlotWidgets_ = {}

    local items = InventorySystem.GetItemsByCategory(currentTab_)

    if #items == 0 then
        gridContainer_:AddChild(UI.Label {
            text = "暂无" .. (TAB_NAMES[currentTab_] or "") .. "物品",
            fontSize = 13,
            fontColor = { 130, 130, 140, 160 },
            marginTop = 20,
        })
        return
    end

    -- 分页计算
    local totalItems = #items
    local totalPages = math.ceil(totalItems / ITEMS_PER_PAGE)
    if currentPage_ > totalPages then currentPage_ = totalPages end
    if currentPage_ < 1 then currentPage_ = 1 end
    local startIdx = (currentPage_ - 1) * ITEMS_PER_PAGE + 1
    local endIdx = math.min(currentPage_ * ITEMS_PER_PAGE, totalItems)

    -- 网格容器
    local grid = UI.Panel {
        flexDirection = "row",
        flexWrap = "wrap",
        gap = 4,
        width = "100%",
    }

    for idx = startIdx, endIdx do
        local item = items[idx]
        local clr = RarityData.GetRarityColor(item.rarity or 1)
        local isEquipped = InventorySystem.IsEquipped(item.uid)

        -- 已装备物品的边框颜色为蓝色
        local borderClr = isEquipped
            and { 100, 180, 255, 220 }
            or { clr[1], clr[2], clr[3], 120 }

        -- 已装备物品的背景更亮
        local bgClr = isEquipped
            and { 35, 50, 65, 240 }
            or { 32, 35, 45, 220 }

        local capturedItem = item
        local slotItem = toSlotItem(item)

        -- 用 Panel 包装 ItemSlot
        local cellContainer = UI.Panel {
            width = GRID_CELL_SIZE + 4,
            alignItems = "center",
        }

        local slot = UI.ItemSlot {
            slotId = "grid_" .. idx,
            slotCategory = "grid",
            slotType = "any",
            size = GRID_CELL_SIZE,
            item = slotItem,
            dragContext = dragContext_,
            backgroundColor = bgClr,
            borderColor = borderClr,
            onSlotClick = function(s, slotItemData)
                showDetail(capturedItem)
            end,
        }
        gridSlotWidgets_[idx] = slot
        cellContainer:AddChild(slot)

        -- 物品名（截断显示）
        local shortName = getItemDisplayName(item)
        if #shortName > 4 then
            shortName = string.sub(shortName, 1, 6) .. ".."
        end
        cellContainer:AddChild(UI.Label {
            text = shortName,
            fontSize = 9,
            fontColor = clr,
            textAlign = "center",
            marginTop = 1,
        })

        -- 已装备标记
        if isEquipped then
            cellContainer:AddChild(UI.Label {
                text = "装备中",
                fontSize = 8,
                fontColor = { 100, 200, 255, 180 },
                textAlign = "center",
            })
        end

        grid:AddChild(cellContainer)
    end

    gridContainer_:AddChild(grid)

    -- 分页控制栏（仅多于1页时显示）
    if totalPages > 1 then
        local pageBar = UI.Panel {
            flexDirection = "row",
            justifyContent = "center",
            alignItems = "center",
            width = "100%",
            marginTop = 6,
            gap = 8,
        }
        -- 上一页
        pageBar:AddChild(UI.Button {
            text = "◀",
            fontSize = 13,
            width = 36, height = 28,
            variant = "secondary",
            borderRadius = 4,
            disabled = currentPage_ <= 1,
            onClick = function()
                currentPage_ = currentPage_ - 1
                refreshGrid()
            end,
        })
        -- 页码
        pageBar:AddChild(UI.Label {
            text = currentPage_ .. "/" .. totalPages,
            fontSize = 12,
            fontColor = { 200, 200, 210, 220 },
        })
        -- 下一页
        pageBar:AddChild(UI.Button {
            text = "▶",
            fontSize = 13,
            width = 36, height = 28,
            variant = "secondary",
            borderRadius = 4,
            disabled = currentPage_ >= totalPages,
            onClick = function()
                currentPage_ = currentPage_ + 1
                refreshGrid()
            end,
        })
        gridContainer_:AddChild(pageBar)
    end
end

-- ============================================================================
-- 初始化
-- ============================================================================

function CharacterPanelUI.Init()
    -- 创建 DragDropContext
    dragContext_ = UI.DragDropContext {
        onDragStart = onDragStart,
        onDragEnd = onDragEnd,
        onDragCancel = onDragCancel,
        canDrop = canDrop,
    }

    -- 详情面板
    detailPanel_ = UI.Panel {
        id = "charDetailPanel",
        width = "100%",
        flexGrow = 1,
        padding = 10,
    }

    -- 觉醒进度面板
    awakeningPanel_ = UI.Panel {
        id = "charAwakeningPanel",
        width = "100%",
        padding = 8,
        marginBottom = 8,
        backgroundColor = { 20, 22, 30, 180 },
        borderRadius = 8,
    }

    -- 装备槽面板
    equipSlotsPanel_ = UI.Panel {
        id = "charEquipSlots",
        width = "100%",
        padding = 8,
        marginBottom = 8,
        backgroundColor = { 20, 22, 30, 180 },
        borderRadius = 8,
    }

    -- 物品网格容器
    gridContainer_ = UI.Panel {
        id = "charItemGrid",
        width = "100%",
    }

    -- Tab 按钮
    local function makeTabBtn(cat)
        local label = TAB_NAMES[cat] or cat
        return UI.Button {
            text = label,
            variant = currentTab_ == cat and "primary" or "secondary",
            marginRight = 4,
            minWidth = 60,
            onClick = function()
                currentTab_ = cat
                currentPage_ = 1
                CharacterPanelUI.Refresh()
            end,
        }
    end

    panelRoot_ = UI.Panel {
        id = "characterPanel",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 10, 10, 20, 210 },
        justifyContent = "center",
        alignItems = "center",
        visible = false,
        children = {
            UI.Panel {
                width = "90%",
                maxWidth = 720,
                height = "88%",
                backgroundColor = { 22, 22, 32, 245 },
                borderRadius = 14,
                borderWidth = 2,
                borderColor = { 140, 120, 80, 160 },
                padding = 16,
                children = {
                    -- 标题栏
                    UI.Panel {
                        flexDirection = "row",
                        justifyContent = "space-between",
                        alignItems = "center",
                        marginBottom = 10,
                        children = {
                            UI.Label {
                                text = "角色面板",
                                fontSize = 20,
                                fontWeight = "bold",
                                fontColor = { 240, 220, 160, 255 },
                            },
                            UI.Label {
                                id = "charItemCount",
                                text = "0/80",
                                fontSize = 13,
                                fontColor = { 160, 160, 170, 200 },
                            },
                        },
                    },
                    -- Tab 栏
                    UI.Panel {
                        id = "charTabBar",
                        flexDirection = "row",
                        marginBottom = 10,
                        children = {
                            makeTabBtn("weapon"),
                            makeTabBtn("equipment"),
                            makeTabBtn("item"),
                        },
                    },
                    -- 分隔线
                    UI.Panel {
                        width = "100%", height = 1,
                        backgroundColor = { 140, 120, 80, 60 },
                        marginBottom = 8,
                    },
                    -- 主体区域（左：装备栏+物品网格 | 右：觉醒+详情）
                    UI.Panel {
                        flexDirection = "row",
                        flexGrow = 1,
                        flexShrink = 1,
                        width = "100%",
                        children = {
                            -- 左侧：装备栏 + 物品网格（上下排列，对齐）
                            UI.Panel {
                                width = "55%",
                                flexGrow = 1,
                                flexShrink = 1,
                                marginRight = 8,
                                children = {
                                    equipSlotsPanel_,
                                    UI.ScrollView {
                                        flexGrow = 1,
                                        flexShrink = 1,
                                        width = "100%",
                                        children = { gridContainer_ },
                                    },
                                },
                            },
                            -- 右侧：觉醒 + 详情
                            UI.Panel {
                                width = "42%",
                                flexShrink = 0,
                                children = {
                                    awakeningPanel_,
                                    UI.ScrollView {
                                        flexGrow = 1,
                                        width = "100%",
                                        children = { detailPanel_ },
                                    },
                                },
                            },
                        },
                    },
                    -- 底部提示
                    UI.Panel {
                        marginTop = 8,
                        alignItems = "center",
                        children = {
                            UI.Label {
                                text = "按 Tab 或 ESC 关闭 | 拖拽物品到装备槽可快速装备",
                                fontSize = 11,
                                fontColor = { 140, 140, 140, 130 },
                            },
                        },
                    },
                },
            },
            -- DragDropContext 放在面板最外层，确保拖拽图标显示在最上层
            dragContext_,
        },
    }

    print("[CharacterPanelUI] 初始化完成（网格模式 + 拖拽装备）")
    return panelRoot_
end

-- ============================================================================
-- 刷新
-- ============================================================================

function CharacterPanelUI.Refresh()
    if not panelRoot_ then return end

    -- 更新 Tab 按钮高亮（重建 Tab 栏）
    local tabBar = panelRoot_:FindById("charTabBar")
    if tabBar then
        UIHelper.DestroyChildren(tabBar)
        for _, cat in ipairs({ "weapon", "equipment", "item" }) do
            local label = TAB_NAMES[cat] or cat
            local capturedCat = cat
            tabBar:AddChild(UI.Button {
                text = label,
                variant = currentTab_ == cat and "primary" or "secondary",
                marginRight = 4,
                minWidth = 60,
                onClick = function()
                    currentTab_ = capturedCat
                    currentPage_ = 1
                    CharacterPanelUI.Refresh()
                end,
            })
        end
    end

    -- 更新物品计数
    local countLabel = panelRoot_:FindById("charItemCount")
    if countLabel then
        countLabel:SetText(InventorySystem.GetItemCount() .. "/80")
    end

    -- 刷新网格、装备槽和觉醒进度
    refreshGrid()
    refreshEquipSlots()
    refreshAwakeningBar()
    showDetail(nil)
end

-- ============================================================================
-- 显示 / 隐藏
-- ============================================================================

function CharacterPanelUI.Show()
    if isActive_ then return end
    isActive_ = true

    GameManager.SetState(GameConfig.States.CHARACTER_PANEL)
    FirstPersonController.SetMouseAbsolute()

    CharacterPanelUI.Refresh()

    if panelRoot_ then
        panelRoot_:Show()
    end
end

function CharacterPanelUI.Hide()
    if not isActive_ then return end
    isActive_ = false

    GameManager.SetState(GameConfig.States.PLAYING)
    FirstPersonController.SetMouseRelative()

    if panelRoot_ then
        panelRoot_:Hide()
    end
end

function CharacterPanelUI.Toggle()
    if isActive_ then
        CharacterPanelUI.Hide()
    else
        CharacterPanelUI.Show()
    end
end

-- ============================================================================
-- 每帧更新
-- ============================================================================

function CharacterPanelUI.Update(dt)
    if not isActive_ then return end

    if input:GetKeyPress(KEY_TAB) or input:GetKeyPress(KEY_ESCAPE) then
        CharacterPanelUI.Hide()
    end
end

---@return boolean
function CharacterPanelUI.IsActive()
    return isActive_
end

---@return table
function CharacterPanelUI.GetRoot()
    return panelRoot_
end

return CharacterPanelUI
