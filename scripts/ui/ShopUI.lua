-- ============================================================================
-- ShopUI.lua — 嗡摩佬的武器商店（买卖双模式）
-- 与嗡摩佬对话结束后自动打开，可用金币购买武器/出售物品
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local RarityData = require("data.RarityData")
local AffixSystem = require("systems.AffixSystem")
local AffixDatabase = require("data.AffixDatabase")
local UI = require("urhox-libs/UI")
local UIHelper = require("ui.UIHelper")

local ShopUI = {}

local root_ = nil
local goldLabel_ = nil
local itemsContainer_ = nil
local onClose_ = nil
local isOpen_ = false

-- 买卖模式
local mode_ = "buy" -- "buy" | "sell" | "forge"
local buyTabBtn_ = nil
local sellTabBtn_ = nil
local forgeTabBtn_ = nil
local titleLabel_ = nil
local subtitleLabel_ = nil

-- 出售详情面板
local detailPanel_ = nil
local detailNameLabel_ = nil
local detailRarityLabel_ = nil
local detailDescLabel_ = nil
local detailAffixContainer_ = nil
local detailPriceLabel_ = nil
local sellConfirmBtn_ = nil
local selectedSellUID_ = nil

-- 锻造模式状态
local forgeSelectedUID_ = nil      -- 当前选中锻造物品
local forgeSubMode_ = "crystal"    -- "crystal" | "refresh"

-- 依赖注入
---@type table
local InventorySystem_ = nil

-- ============================================================================
-- 售价公式
-- ============================================================================

--- 武器基础售价表（商店购买价 × 0.4）
local WEAPON_BASE_SELL = {}
for wid, price in pairs(GameConfig.Shop.Prices) do
    WEAPON_BASE_SELL[wid] = math.floor(price * 0.4)
end
-- 铁剑无售价（不可出售）
WEAPON_BASE_SELL["iron_sword"] = 0

--- 装备基础售价（基于被动属性价值）
local EQUIP_BASE_SELL = {
    verdant_heartwood = 80,
    stonecore_sigil   = 90,
    phantom_shackle   = 75,
    ember_fang        = 85,
    demon_mask_shard  = 100,
}

--- 道具基础售价
local ITEM_BASE_SELL = 20

--- 品级售价倍率
local RARITY_SELL_MULT = {
    [1] = 1.0,  -- 普通
    [2] = 1.5,  -- 优秀
    [3] = 2.5,  -- 稀有
    [4] = 4.0,  -- 史诗
    [5] = 7.0,  -- 传说
}

--- 计算物品售价
---@param item table 物品实例
---@return number price
function ShopUI.CalcSellPrice(item)
    if not item then return 0 end

    -- 铁剑不可出售
    if item.baseId == "iron_sword" then return 0 end

    -- 基础售价
    local basePrice = 0
    if item.category == "weapon" then
        basePrice = WEAPON_BASE_SELL[item.baseId] or 30
    elseif item.category == "equipment" then
        basePrice = EQUIP_BASE_SELL[item.baseId] or 50
    else
        basePrice = ITEM_BASE_SELL
    end

    -- 品级倍率
    local rarityMult = RARITY_SELL_MULT[item.rarity] or 1.0
    local price = basePrice * rarityMult

    -- 词条加成（每个词条按 value/max 比例贡献 10~30 金币）
    if item.affixes then
        for _, affix in ipairs(item.affixes) do
            local maxVal = 15 -- 默认最大值
            for _, def in ipairs(RarityData.AffixPool) do
                if def.stat == affix.stat then
                    maxVal = def.max
                    break
                end
            end
            local ratio = (affix.value or 0) / maxVal
            price = price + 10 + math.floor(20 * ratio)
        end
    end

    return math.max(1, math.floor(price))
end

-- ============================================================================
-- 标签页切换
-- ============================================================================

local function setTabActive(btn, active)
    if not btn then return end
    if active then
        btn:SetStyle({ backgroundColor = { 200, 160, 60, 220 }, fontColor = { 20, 18, 30, 255 } })
    else
        btn:SetStyle({ backgroundColor = { 60, 50, 80, 200 }, fontColor = { 180, 180, 200, 200 } })
    end
end

-- 前向声明
local buildBuyCards
local buildSellCards
local buildForgeCards

-- 分页相关
local SHOP_ITEMS_PER_PAGE = 16
local shopPage_ = 1

--- detailPanel_ 的出售子元素是否被锻造模式破坏
local detailDirty_ = false

--- 重建 detailPanel_ 的出售模式子元素（锻造后恢复用）
local function rebuildSellDetailChildren()
    if not detailPanel_ then return end
    UIHelper.DestroyChildren(detailPanel_)

    detailNameLabel_ = UI.Label {
        id = "sellDetailName", text = "",
        fontSize = 16, fontWeight = "bold",
        fontColor = { 255, 240, 200, 255 },
        marginBottom = 4, textAlign = "center",
    }
    detailRarityLabel_ = UI.Label {
        id = "sellDetailRarity", text = "",
        fontSize = 11, fontColor = { 180, 180, 200, 180 },
        marginBottom = 6,
    }
    detailDescLabel_ = UI.Label {
        id = "sellDetailDesc", text = "",
        fontSize = 10, fontColor = { 160, 160, 180, 160 },
        marginBottom = 10, textAlign = "center",
    }
    detailAffixContainer_ = UI.Panel {
        id = "sellDetailAffixes", width = "100%",
        marginBottom = 12, alignItems = "center",
    }
    detailPriceLabel_ = UI.Label {
        id = "sellDetailPrice", text = "",
        fontSize = 16, fontWeight = "bold",
        fontColor = { 255, 220, 80, 255 },
        marginBottom = 12,
    }
    sellConfirmBtn_ = UI.Button {
        id = "sellConfirmBtn", text = "确认出售",
        fontSize = 13, fontWeight = "bold",
        width = 160, height = 34,
        variant = "warning", borderRadius = 8,
        onClick = function() ShopUI.SellItem() end,
    }

    detailPanel_:AddChild(detailNameLabel_)
    detailPanel_:AddChild(detailRarityLabel_)
    detailPanel_:AddChild(detailDescLabel_)
    detailPanel_:AddChild(detailAffixContainer_)
    detailPanel_:AddChild(detailPriceLabel_)
    detailPanel_:AddChild(sellConfirmBtn_)
    detailPanel_:AddChild(UI.Button {
        text = "取消", fontSize = 11,
        width = 100, height = 26,
        variant = "secondary", borderRadius = 6,
        marginTop = 6,
        onClick = function()
            selectedSellUID_ = nil
            if detailPanel_ then detailPanel_:Hide() end
        end,
    })

    detailDirty_ = false
end

local function switchMode(newMode)
    if mode_ == newMode then return end
    mode_ = newMode
    shopPage_ = 1
    selectedSellUID_ = nil
    forgeSelectedUID_ = nil

    setTabActive(buyTabBtn_, mode_ == "buy")
    setTabActive(sellTabBtn_, mode_ == "sell")
    setTabActive(forgeTabBtn_, mode_ == "forge")

    if mode_ == "buy" then
        if titleLabel_ then titleLabel_:SetText("嗡摩佬的商店") end
        if subtitleLabel_ then subtitleLabel_:SetText("选购武器和法器") end
        if detailDirty_ then rebuildSellDetailChildren() end
        if detailPanel_ then detailPanel_:Hide() end
        buildBuyCards()
    elseif mode_ == "sell" then
        if titleLabel_ then titleLabel_:SetText("嗡摩佬的回收站") end
        if subtitleLabel_ then subtitleLabel_:SetText("出售你不需要的物品") end
        if detailDirty_ then rebuildSellDetailChildren() end
        if detailPanel_ then detailPanel_:Hide() end
        buildSellCards()
    else -- forge
        if titleLabel_ then titleLabel_:SetText("嗡摩佬的锻造台") end
        if subtitleLabel_ then subtitleLabel_:SetText("水晶扩槽 / 词条刷新") end
        if detailPanel_ then detailPanel_:Hide() end
        buildForgeCards()
    end
end

-- ============================================================================
-- 购买模式 - 武器卡片构建
-- ============================================================================

buildBuyCards = function()
    if not itemsContainer_ then return end
    UIHelper.DestroyChildren(itemsContainer_)

    local prices = GameConfig.Shop.Prices
    local currentGold = GameManager.GetGold()

    for _, weaponId in ipairs(GameConfig.Weapons.Order) do
        if weaponId == "iron_sword" then goto continue end

        local weapon = GameConfig.Weapons[weaponId]
        if not weapon then goto continue end

        local price = prices[weaponId] or 999
        local owned = GameManager.HasItem(weaponId)
        local canAfford = currentGold >= price

        local bgColor, borderColor
        if owned then
            bgColor = { 25, 40, 25, 210 }
            borderColor = { 80, 160, 80, 150 }
        elseif canAfford then
            bgColor = { 25, 22, 40, 220 }
            borderColor = { 200, 160, 60, 180 }
        else
            bgColor = { 35, 25, 25, 200 }
            borderColor = { 80, 50, 50, 120 }
        end

        local btnText, btnVariant, btnDisabled
        if owned then
            btnText = "已拥有"
            btnVariant = "secondary"
            btnDisabled = true
        elseif canAfford then
            btnText = "💰" .. price
            btnVariant = "primary"
            btnDisabled = false
        else
            btnText = "💰" .. price
            btnVariant = "secondary"
            btnDisabled = true
        end

        local cardWeaponId = weaponId
        local cardPrice = price

        itemsContainer_:AddChild(UI.Panel {
            width = 130, margin = 5, padding = { 10, 8 },
            backgroundColor = bgColor,
            borderRadius = 8, borderWidth = 2,
            borderColor = borderColor,
            alignItems = "center",
            children = {
                UI.Label {
                    text = weapon.icon or "?",
                    fontSize = 28,
                    marginBottom = 4,
                },
                UI.Label {
                    text = weapon.name,
                    fontSize = 12,
                    fontWeight = "bold",
                    fontColor = { 255, 240, 200, 255 },
                    marginBottom = 2,
                    textAlign = "center",
                },
                UI.Label {
                    text = weapon.skill or "",
                    fontSize = 10,
                    fontColor = { 180, 180, 200, 160 },
                    marginBottom = 8,
                    textAlign = "center",
                },
                UI.Button {
                    text = btnText,
                    fontSize = 11,
                    width = 100, height = 28,
                    variant = btnVariant,
                    borderRadius = 6,
                    disabled = btnDisabled,
                    onClick = function()
                        if not owned and canAfford then
                            ShopUI.PurchaseWeapon(cardWeaponId, cardPrice)
                        end
                    end,
                },
            },
        })

        ::continue::
    end
end

-- ============================================================================
-- 出售模式 - 仓库物品列表
-- ============================================================================

local function getItemDisplayInfo(item)
    local icon, name, desc = "?", "未知", ""
    if item.category == "weapon" then
        local wCfg = GameConfig.Weapons[item.baseId]
        if wCfg then
            icon = wCfg.icon or "?"
            name = wCfg.name or item.baseId
            desc = wCfg.skill or ""
        end
    elseif item.category == "equipment" then
        local eCfg = GameConfig.Equipment[item.baseId]
        if eCfg then
            icon = eCfg.icon or "?"
            name = eCfg.name or item.baseId
            desc = eCfg.desc or ""
        end
    else
        name = item.baseId
    end
    return icon, name, desc
end

buildSellCards = function()
    if not itemsContainer_ then return end
    UIHelper.DestroyChildren(itemsContainer_)

    if not InventorySystem_ then
        itemsContainer_:AddChild(UI.Label {
            text = "仓库未初始化",
            fontSize = 14, fontColor = { 180, 80, 80, 255 },
        })
        return
    end

    -- 收集所有可出售物品
    local allItems = {}
    local cats = { "weapon", "equipment", "item" }
    for _, cat in ipairs(cats) do
        local catItems = InventorySystem_.GetItemsByCategory(cat)
        for _, item in ipairs(catItems) do
            table.insert(allItems, item)
        end
    end

    if #allItems == 0 then
        itemsContainer_:AddChild(UI.Label {
            text = "仓库空空如也",
            fontSize = 14, fontColor = { 140, 140, 160, 200 },
            marginTop = 40,
        })
        return
    end

    -- 按品级降序排列
    table.sort(allItems, function(a, b)
        if a.rarity ~= b.rarity then return a.rarity > b.rarity end
        return a.baseId < b.baseId
    end)

    -- 分页
    local totalItems = #allItems
    local totalPages = math.ceil(totalItems / SHOP_ITEMS_PER_PAGE)
    if shopPage_ > totalPages then shopPage_ = totalPages end
    if shopPage_ < 1 then shopPage_ = 1 end
    local startIdx = (shopPage_ - 1) * SHOP_ITEMS_PER_PAGE + 1
    local endIdx = math.min(shopPage_ * SHOP_ITEMS_PER_PAGE, totalItems)

    for i = startIdx, endIdx do
        local item = allItems[i]
        local icon, name, _ = getItemDisplayInfo(item)
        local sellPrice = ShopUI.CalcSellPrice(item)
        local rarityColor = RarityData.GetRarityColor(item.rarity)
        local rarityName = RarityData.GetRarityName(item.rarity)
        local isEquipped = InventorySystem_.IsEquipped(item.uid)
        local isSellable = sellPrice > 0

        -- 卡片背景
        local bgColor = { 30, 28, 42, 220 }
        local borderColor = { rarityColor[1], rarityColor[2], rarityColor[3], 120 }

        if not isSellable then
            bgColor = { 35, 30, 30, 180 }
            borderColor = { 80, 60, 60, 100 }
        end

        local cardUID = item.uid
        local cardItem = item

        -- 分类标签
        local catLabel = ""
        if item.category == "weapon" then catLabel = "武器"
        elseif item.category == "equipment" then catLabel = "装备"
        else catLabel = "道具" end

        itemsContainer_:AddChild(UI.Panel {
            width = 130, margin = 5, padding = { 10, 8 },
            backgroundColor = bgColor,
            borderRadius = 8, borderWidth = 2,
            borderColor = borderColor,
            alignItems = "center",
            children = {
                -- 图标
                UI.Label {
                    text = icon,
                    fontSize = 28,
                    marginBottom = 2,
                },
                -- 名称（品级颜色）
                UI.Label {
                    text = name,
                    fontSize = 12,
                    fontWeight = "bold",
                    fontColor = rarityColor,
                    marginBottom = 1,
                    textAlign = "center",
                },
                -- 品级 + 分类
                UI.Label {
                    text = rarityName .. " " .. catLabel,
                    fontSize = 9,
                    fontColor = { rarityColor[1], rarityColor[2], rarityColor[3], 160 },
                    marginBottom = 2,
                },
                -- 词条数提示
                UI.Label {
                    text = (item.affixes and #item.affixes > 0)
                        and ("词条×" .. #item.affixes) or "",
                    fontSize = 9,
                    fontColor = { 180, 160, 100, 150 },
                    marginBottom = 4,
                },
                -- 已装备标记
                isEquipped and UI.Label {
                    text = "【已装备】",
                    fontSize = 9,
                    fontColor = { 100, 200, 255, 200 },
                    marginBottom = 4,
                } or UI.Label { text = "", height = 0 },
                -- 售价/操作按钮
                UI.Button {
                    text = isSellable and ("售 💰" .. sellPrice) or "不可售",
                    fontSize = 10,
                    width = 105, height = 26,
                    variant = isSellable and "warning" or "secondary",
                    borderRadius = 6,
                    disabled = not isSellable,
                    onClick = function()
                        if isSellable then
                            ShopUI.SelectForSell(cardUID)
                        end
                    end,
                },
            },
        })
    end

    -- 分页控制栏
    if totalPages > 1 then
        itemsContainer_:AddChild(UI.Panel {
            flexDirection = "row",
            justifyContent = "center",
            alignItems = "center",
            width = "100%",
            marginTop = 8,
            gap = 8,
            children = {
                UI.Button {
                    text = "◀", fontSize = 13,
                    width = 36, height = 28,
                    variant = "secondary", borderRadius = 4,
                    disabled = shopPage_ <= 1,
                    onClick = function()
                        shopPage_ = shopPage_ - 1
                        buildSellCards()
                    end,
                },
                UI.Label {
                    text = shopPage_ .. "/" .. totalPages,
                    fontSize = 12,
                    fontColor = { 200, 200, 210, 220 },
                },
                UI.Button {
                    text = "▶", fontSize = 13,
                    width = 36, height = 28,
                    variant = "secondary", borderRadius = 4,
                    disabled = shopPage_ >= totalPages,
                    onClick = function()
                        shopPage_ = shopPage_ + 1
                        buildSellCards()
                    end,
                },
            },
        })
    end
end

-- ============================================================================
-- 出售详情面板
-- ============================================================================

function ShopUI.SelectForSell(uid)
    if not InventorySystem_ then return end
    local item = InventorySystem_.GetItem(uid)
    if not item then return end

    selectedSellUID_ = uid

    local icon, name, desc = getItemDisplayInfo(item)
    local sellPrice = ShopUI.CalcSellPrice(item)
    local rarityColor = RarityData.GetRarityColor(item.rarity)
    local rarityName = RarityData.GetRarityName(item.rarity)
    local isEquipped = InventorySystem_.IsEquipped(uid)

    -- 更新详情面板
    if detailNameLabel_ then
        detailNameLabel_:SetText(icon .. " " .. name)
        detailNameLabel_:SetFontColor(rarityColor)
    end
    if detailRarityLabel_ then
        detailRarityLabel_:SetText(rarityName .. (isEquipped and " 【已装备】" or ""))
    end
    if detailDescLabel_ then
        detailDescLabel_:SetText(desc)
    end
    if detailPriceLabel_ then
        detailPriceLabel_:SetText("售价: 💰" .. sellPrice)
    end

    -- 词条列表
    if detailAffixContainer_ then
        UIHelper.DestroyChildren(detailAffixContainer_)
        if item.affixes and #item.affixes > 0 then
            for _, affix in ipairs(item.affixes) do
                detailAffixContainer_:AddChild(UI.Label {
                    text = RarityData.FormatAffix(affix),
                    fontSize = 11,
                    fontColor = { 180, 220, 140, 255 },
                    marginBottom = 2,
                })
            end
        else
            detailAffixContainer_:AddChild(UI.Label {
                text = "无词条",
                fontSize = 11,
                fontColor = { 120, 120, 140, 160 },
            })
        end
    end

    -- 确认按钮
    if sellConfirmBtn_ then
        sellConfirmBtn_:SetText("确认出售 💰" .. sellPrice)
        sellConfirmBtn_:SetDisabled(false)
    end

    if detailPanel_ then detailPanel_:Show() end
end

-- ============================================================================
-- 执行出售
-- ============================================================================

function ShopUI.SellItem()
    if not selectedSellUID_ or not InventorySystem_ then return end

    local item = InventorySystem_.GetItem(selectedSellUID_)
    if not item then
        selectedSellUID_ = nil
        return
    end

    -- 铁剑保护
    if item.baseId == "iron_sword" then
        print("[Shop] 铁剑不可出售")
        return
    end

    local sellPrice = ShopUI.CalcSellPrice(item)

    -- 移除物品
    local removed = InventorySystem_.RemoveItem(selectedSellUID_)
    if not removed then return end

    -- 如果是武器，通知 WeaponSystem 刷新
    if item.category == "weapon" then
        local WeaponSystem = require("combat.WeaponSystem")
        WeaponSystem.RefreshWeapons()
    end

    -- 如果是装备，通知 EquipmentSystem 刷新
    if item.category == "equipment" then
        local EquipmentSystem = require("combat.EquipmentSystem")
        -- 需要同步 playerData 的 equipment 表
        local pd = GameManager.GetPlayerData()
        if pd and pd.equipment then
            pd.equipment[item.baseId] = nil
        end
    end

    -- 获得金币
    GameManager.AddGold(sellPrice)

    -- 音效和通知
    local AudioManager = require("core.AudioManager")
    AudioManager.PlayItemPickup()
    local HUD = require("ui.HUD")
    HUD.ShowNotification("出售成功 +" .. sellPrice .. " 金币", { 255, 220, 80, 255 })

    print("[Shop] 出售: " .. (item.baseId or "?")
        .. " [" .. RarityData.GetRarityName(item.rarity) .. "]"
        .. " 获得 " .. sellPrice .. " 金币")

    -- 更新UI
    selectedSellUID_ = nil
    if detailPanel_ then detailPanel_:Hide() end
    if goldLabel_ then
        goldLabel_:SetText("💰 " .. GameManager.GetGold())
    end
    buildSellCards()
end

-- ============================================================================
-- 锻造模式 - 物品选择 + 水晶/刷新操作
-- ============================================================================

buildForgeCards = function()
    if not itemsContainer_ then return end
    UIHelper.DestroyChildren(itemsContainer_)

    if not InventorySystem_ then
        itemsContainer_:AddChild(UI.Label {
            text = "仓库未初始化",
            fontSize = 14, fontColor = { 180, 80, 80, 255 },
        })
        return
    end

    -- 收集所有物品
    local allItems = {}
    for _, cat in ipairs({ "weapon", "equipment", "item" }) do
        local catItems = InventorySystem_.GetItemsByCategory(cat)
        for _, item in ipairs(catItems) do
            if item.baseId ~= "iron_sword" then
                table.insert(allItems, item)
            end
        end
    end

    if #allItems == 0 then
        itemsContainer_:AddChild(UI.Label {
            text = "没有可锻造的物品",
            fontSize = 14, fontColor = { 140, 140, 160, 200 },
            marginTop = 40,
        })
        return
    end

    -- 按品级降序
    table.sort(allItems, function(a, b)
        if a.rarity ~= b.rarity then return a.rarity > b.rarity end
        return a.baseId < b.baseId
    end)

    -- 分页
    local totalItems = #allItems
    local totalPages = math.ceil(totalItems / SHOP_ITEMS_PER_PAGE)
    if shopPage_ > totalPages then shopPage_ = totalPages end
    if shopPage_ < 1 then shopPage_ = 1 end
    local startIdx = (shopPage_ - 1) * SHOP_ITEMS_PER_PAGE + 1
    local endIdx = math.min(shopPage_ * SHOP_ITEMS_PER_PAGE, totalItems)

    for i = startIdx, endIdx do
        local item = allItems[i]
        local icon, name, _ = getItemDisplayInfo(item)
        local rarityColor = RarityData.GetRarityColor(item.rarity)
        local rarityName = RarityData.GetRarityName(item.rarity)
        local affixCount = item.affixes and #item.affixes or 0
        local maxSlots = item.maxSlots or AffixSystem.DEFAULT_MAX_SLOTS
        local isSelected = (forgeSelectedUID_ == item.uid)

        local bgColor = isSelected
            and { 40, 35, 60, 240 }
            or { 30, 28, 42, 220 }
        local borderColor = isSelected
            and { 200, 160, 60, 220 }
            or { rarityColor[1], rarityColor[2], rarityColor[3], 120 }

        local cardUID = item.uid
        itemsContainer_:AddChild(UI.Panel {
            width = 130, margin = 5, padding = { 10, 8 },
            backgroundColor = bgColor,
            borderRadius = 8, borderWidth = 2,
            borderColor = borderColor,
            alignItems = "center",
            children = {
                UI.Label { text = icon, fontSize = 28, marginBottom = 2 },
                UI.Label {
                    text = name, fontSize = 12, fontWeight = "bold",
                    fontColor = rarityColor, marginBottom = 1, textAlign = "center",
                },
                UI.Label {
                    text = rarityName,
                    fontSize = 9, fontColor = { rarityColor[1], rarityColor[2], rarityColor[3], 160 },
                    marginBottom = 2,
                },
                UI.Label {
                    text = "词条 " .. affixCount .. "/" .. maxSlots,
                    fontSize = 10, fontColor = { 180, 200, 140, 200 },
                    marginBottom = 4,
                },
                UI.Button {
                    text = isSelected and "已选中" or "选择",
                    fontSize = 10, width = 100, height = 24,
                    variant = isSelected and "primary" or "secondary",
                    borderRadius = 6,
                    onClick = function()
                        ShopUI.SelectForForge(cardUID)
                    end,
                },
            },
        })
    end

    -- 分页控制栏
    if totalPages > 1 then
        itemsContainer_:AddChild(UI.Panel {
            flexDirection = "row",
            justifyContent = "center",
            alignItems = "center",
            width = "100%",
            marginTop = 8,
            gap = 8,
            children = {
                UI.Button {
                    text = "◀", fontSize = 13,
                    width = 36, height = 28,
                    variant = "secondary", borderRadius = 4,
                    disabled = shopPage_ <= 1,
                    onClick = function()
                        shopPage_ = shopPage_ - 1
                        buildForgeCards()
                    end,
                },
                UI.Label {
                    text = shopPage_ .. "/" .. totalPages,
                    fontSize = 12,
                    fontColor = { 200, 200, 210, 220 },
                },
                UI.Button {
                    text = "▶", fontSize = 13,
                    width = 36, height = 28,
                    variant = "secondary", borderRadius = 4,
                    disabled = shopPage_ >= totalPages,
                    onClick = function()
                        shopPage_ = shopPage_ + 1
                        buildForgeCards()
                    end,
                },
            },
        })
    end
end

--- 选择物品进入锻造详情
function ShopUI.SelectForForge(uid)
    if not InventorySystem_ then return end
    local item = InventorySystem_.GetItem(uid)
    if not item then return end

    forgeSelectedUID_ = uid
    buildForgeCards() -- 刷新左侧高亮
    ShopUI.ShowForgeDetail(item)
end

--- 显示锻造详情面板
function ShopUI.ShowForgeDetail(item)
    if not detailPanel_ then return end
    UIHelper.DestroyChildren(detailPanel_)
    detailDirty_ = true

    local icon, name, _ = getItemDisplayInfo(item)
    local rarityColor = RarityData.GetRarityColor(item.rarity)
    local rarityName = RarityData.GetRarityName(item.rarity)
    local affixCount = item.affixes and #item.affixes or 0
    local maxSlots = item.maxSlots or AffixSystem.DEFAULT_MAX_SLOTS
    local currentGold = GameManager.GetGold()

    -- 物品信息
    detailPanel_:AddChild(UI.Label {
        text = icon .. " " .. name,
        fontSize = 15, fontWeight = "bold", fontColor = rarityColor,
        marginBottom = 2, textAlign = "center",
    })
    detailPanel_:AddChild(UI.Label {
        text = rarityName .. " | 词条 " .. affixCount .. "/" .. maxSlots,
        fontSize = 11, fontColor = { 180, 180, 200, 200 },
        marginBottom = 8,
    })

    -- 当前词条列表
    if item.affixes and #item.affixes > 0 then
        detailPanel_:AddChild(UI.Label {
            text = "── 当前词条 ──",
            fontSize = 10, fontColor = { 180, 170, 120, 160 },
            marginBottom = 4,
        })
        for idx, affix in ipairs(item.affixes) do
            local qColor = AffixDatabase.GetQualityColor(affix.tier or 1)
            local qName = AffixDatabase.GetQualityName(affix.tier or 1)
            local capturedIdx = idx
            local capturedItem = item

            detailPanel_:AddChild(UI.Panel {
                width = "100%", flexDirection = "row",
                alignItems = "center", marginBottom = 3,
                padding = { 4, 2 },
                backgroundColor = { 30, 28, 45, 180 },
                borderRadius = 4,
                children = {
                    UI.Panel {
                        flexGrow = 1, flexShrink = 1,
                        children = {
                            UI.Label {
                                text = "[" .. qName .. "] " .. AffixDatabase.FormatAffix(affix),
                                fontSize = 10, fontColor = qColor,
                            },
                        },
                    },
                    UI.Button {
                        text = "刷 💰" .. AffixSystem.GetRefreshPrice(capturedItem, capturedIdx),
                        fontSize = 9, width = 70, height = 20,
                        variant = "warning", borderRadius = 4,
                        disabled = currentGold < AffixSystem.GetRefreshPrice(capturedItem, capturedIdx),
                        onClick = function()
                            ShopUI.DoRefreshAffix(capturedItem.uid, capturedIdx)
                        end,
                    },
                },
            })
        end
    else
        detailPanel_:AddChild(UI.Label {
            text = "暂无词条",
            fontSize = 11, fontColor = { 120, 120, 140, 160 },
            marginBottom = 4,
        })
    end

    -- 分隔线
    detailPanel_:AddChild(UI.Panel {
        width = "100%", height = 1,
        backgroundColor = { 100, 100, 100, 60 },
        marginTop = 8, marginBottom = 8,
    })

    -- 水晶扩槽区域
    if maxSlots < AffixSystem.ABSOLUTE_MAX_SLOTS then
        detailPanel_:AddChild(UI.Label {
            text = "── 水晶扩槽 ──",
            fontSize = 10, fontColor = { 140, 180, 220, 180 },
            marginBottom = 6,
        })

        for tier = 1, 6 do
            local crystal = AffixSystem.CrystalTiers[tier]
            local price = crystal.price
            local qColor = AffixDatabase.GetQualityColor(tier)
            local qName = AffixDatabase.GetQualityName(tier)
            local canAfford = currentGold >= price

            local capturedTier = tier
            local capturedUID = item.uid

            detailPanel_:AddChild(UI.Panel {
                width = "100%", flexDirection = "row",
                alignItems = "center", marginBottom = 3,
                padding = { 4, 3 },
                backgroundColor = { 25, 25, 40, 200 },
                borderRadius = 4,
                children = {
                    UI.Label {
                        text = crystal.icon .. " " .. crystal.name,
                        fontSize = 10, fontColor = qColor,
                        flexGrow = 1,
                    },
                    UI.Button {
                        text = "💰" .. price,
                        fontSize = 9, width = 70, height = 20,
                        variant = canAfford and "primary" or "secondary",
                        borderRadius = 4,
                        disabled = not canAfford,
                        onClick = function()
                            ShopUI.DoApplyCrystal(capturedUID, capturedTier)
                        end,
                    },
                },
            })
        end

        detailPanel_:AddChild(UI.Label {
            text = "使用水晶: +1词条槽 + 对应品质词条",
            fontSize = 9, fontColor = { 140, 140, 160, 140 },
            marginTop = 4,
        })
    else
        detailPanel_:AddChild(UI.Label {
            text = "词条槽已达上限",
            fontSize = 11, fontColor = { 255, 200, 80, 200 },
            marginTop = 4,
        })
    end

    detailPanel_:Show()
end

--- 执行水晶扩槽
function ShopUI.DoApplyCrystal(uid, crystalTier)
    if not InventorySystem_ then return end
    local item = InventorySystem_.GetItem(uid)
    if not item then return end

    local crystal = AffixSystem.CrystalTiers[crystalTier]
    if not crystal then return end

    local price = crystal.price
    if not GameManager.SpendGold(price) then
        local HUD = require("ui.HUD")
        HUD.ShowNotification("金币不足！", { 255, 80, 80, 255 })
        return
    end

    local success, msg = AffixSystem.ApplyCrystal(item, crystalTier)
    local HUD = require("ui.HUD")
    local AudioManager = require("core.AudioManager")

    if success then
        AudioManager.PlayItemPickup()
        HUD.ShowNotification("水晶使用成功！", { 100, 255, 200, 255 })
    else
        -- 退还金币
        GameManager.AddGold(price)
        HUD.ShowNotification(msg or "操作失败", { 255, 80, 80, 255 })
    end

    -- 刷新UI
    if goldLabel_ then goldLabel_:SetText("💰 " .. GameManager.GetGold()) end
    ShopUI.ShowForgeDetail(item)
    buildForgeCards()
end

--- 执行词条刷新
function ShopUI.DoRefreshAffix(uid, slotIndex)
    if not InventorySystem_ then return end
    local item = InventorySystem_.GetItem(uid)
    if not item then return end

    local price = AffixSystem.GetRefreshPrice(item, slotIndex)
    if not GameManager.SpendGold(price) then
        local HUD = require("ui.HUD")
        HUD.ShowNotification("金币不足！", { 255, 80, 80, 255 })
        return
    end

    local success, msg = AffixSystem.RefreshAffix(item, slotIndex)
    local HUD = require("ui.HUD")
    local AudioManager = require("core.AudioManager")

    if success then
        AudioManager.PlayItemPickup()
        HUD.ShowNotification("词条刷新成功！", { 200, 220, 100, 255 })
    else
        GameManager.AddGold(price)
        HUD.ShowNotification(msg or "刷新失败", { 255, 80, 80, 255 })
    end

    if goldLabel_ then goldLabel_:SetText("💰 " .. GameManager.GetGold()) end
    ShopUI.ShowForgeDetail(item)
end

-- ============================================================================
-- 购买武器
-- ============================================================================

---@param weaponId string
---@param price number
function ShopUI.PurchaseWeapon(weaponId, price)
    if not GameManager.SpendGold(price) then return end

    GameManager.AddItem(weaponId)

    -- 刷新武器系统
    local WeaponSystem = require("combat.WeaponSystem")
    WeaponSystem.RefreshWeapons()

    -- 音效 + 通知
    local AudioManager = require("core.AudioManager")
    AudioManager.PlayItemPickup()
    local HUD = require("ui.HUD")
    HUD.ShowItemNotify(weaponId)

    -- 更新金币显示和卡片
    if goldLabel_ then
        goldLabel_:SetText("💰 " .. GameManager.GetGold())
    end
    buildBuyCards()

    print("[Shop] 购买武器: " .. weaponId .. " (花费 " .. price .. " 金币)")
end

-- ============================================================================
-- 依赖注入
-- ============================================================================

---@param invSys table InventorySystem 模块
function ShopUI.SetInventorySystem(invSys)
    InventorySystem_ = invSys
    print("[ShopUI] InventorySystem 已注入")
end

-- ============================================================================
-- 初始化
-- ============================================================================

---@return table 面板节点
function ShopUI.Init()
    root_ = UI.Panel {
        id = "shopOverlay",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 190 },
        justifyContent = "center",
        alignItems = "center",
        visible = false,
        children = {
            UI.Panel {
                alignItems = "center",
                width = "92%",
                maxWidth = 780,
                maxHeight = "88%",
                backgroundColor = { 20, 18, 30, 240 },
                borderRadius = 14,
                borderWidth = 2,
                borderColor = { 120, 100, 60, 180 },
                padding = { 20, 24 },
                children = {
                    -- 标题
                    UI.Label {
                        id = "shopTitle",
                        text = "嗡摩佬的商店",
                        fontSize = 24,
                        fontWeight = "bold",
                        fontColor = { 255, 220, 80, 255 },
                        marginBottom = 2,
                    },
                    UI.Label {
                        id = "shopSubtitle",
                        text = "选购武器和法器",
                        fontSize = 12,
                        fontColor = { 180, 180, 200, 160 },
                        marginBottom = 10,
                    },

                    -- 标签页栏
                    UI.Panel {
                        flexDirection = "row",
                        justifyContent = "center",
                        marginBottom = 12,
                        children = {
                            UI.Button {
                                id = "shopBuyTab",
                                text = "购买武器",
                                fontSize = 12,
                                fontWeight = "bold",
                                width = 100, height = 30,
                                borderRadius = 8,
                                marginRight = 6,
                                onClick = function() switchMode("buy") end,
                            },
                            UI.Button {
                                id = "shopSellTab",
                                text = "出售物品",
                                fontSize = 12,
                                fontWeight = "bold",
                                width = 100, height = 30,
                                borderRadius = 8,
                                marginRight = 6,
                                onClick = function() switchMode("sell") end,
                            },
                            UI.Button {
                                id = "shopForgeTab",
                                text = "词条锻造",
                                fontSize = 12,
                                fontWeight = "bold",
                                width = 100, height = 30,
                                borderRadius = 8,
                                onClick = function() switchMode("forge") end,
                            },
                        },
                    },

                    -- 金币显示
                    UI.Label {
                        id = "shopGoldLabel",
                        text = "💰 0",
                        fontSize = 16,
                        fontWeight = "bold",
                        fontColor = { 255, 230, 140, 255 },
                        marginBottom = 12,
                    },

                    -- 主内容区域（左: 列表, 右: 详情）
                    UI.Panel {
                        flexDirection = "row",
                        width = "100%",
                        flexGrow = 1,
                        flexShrink = 1,
                        children = {
                            -- 左侧 - 物品卡片区（滚动）
                            UI.ScrollView {
                                flexGrow = 1,
                                flexShrink = 1,
                                children = {
                                    UI.Panel {
                                        id = "shopItemsGrid",
                                        flexDirection = "row",
                                        flexWrap = "wrap",
                                        justifyContent = "center",
                                        width = "100%",
                                    },
                                },
                            },
                            -- 右侧 - 出售详情面板
                            UI.Panel {
                                id = "shopDetailPanel",
                                visible = false,
                                width = 200,
                                marginLeft = 12,
                                padding = { 14, 12 },
                                backgroundColor = { 35, 30, 50, 230 },
                                borderRadius = 10,
                                borderWidth = 1,
                                borderColor = { 120, 100, 60, 140 },
                                alignItems = "center",
                                flexShrink = 0,
                                children = {
                                    UI.Label {
                                        id = "sellDetailName",
                                        text = "",
                                        fontSize = 16,
                                        fontWeight = "bold",
                                        fontColor = { 255, 240, 200, 255 },
                                        marginBottom = 4,
                                        textAlign = "center",
                                    },
                                    UI.Label {
                                        id = "sellDetailRarity",
                                        text = "",
                                        fontSize = 11,
                                        fontColor = { 180, 180, 200, 180 },
                                        marginBottom = 6,
                                    },
                                    UI.Label {
                                        id = "sellDetailDesc",
                                        text = "",
                                        fontSize = 10,
                                        fontColor = { 160, 160, 180, 160 },
                                        marginBottom = 10,
                                        textAlign = "center",
                                    },
                                    -- 词条容器
                                    UI.Panel {
                                        id = "sellDetailAffixes",
                                        width = "100%",
                                        marginBottom = 12,
                                        alignItems = "center",
                                    },
                                    -- 售价
                                    UI.Label {
                                        id = "sellDetailPrice",
                                        text = "",
                                        fontSize = 16,
                                        fontWeight = "bold",
                                        fontColor = { 255, 220, 80, 255 },
                                        marginBottom = 12,
                                    },
                                    -- 确认出售按钮
                                    UI.Button {
                                        id = "sellConfirmBtn",
                                        text = "确认出售",
                                        fontSize = 13,
                                        fontWeight = "bold",
                                        width = 160, height = 34,
                                        variant = "warning",
                                        borderRadius = 8,
                                        onClick = function()
                                            ShopUI.SellItem()
                                        end,
                                    },
                                    -- 取消按钮
                                    UI.Button {
                                        text = "取消",
                                        fontSize = 11,
                                        width = 100, height = 26,
                                        variant = "secondary",
                                        borderRadius = 6,
                                        marginTop = 6,
                                        onClick = function()
                                            selectedSellUID_ = nil
                                            if detailPanel_ then detailPanel_:Hide() end
                                        end,
                                    },
                                },
                            },
                        },
                    },

                    -- 关闭按钮
                    UI.Button {
                        text = "离开商店",
                        fontSize = 14,
                        width = 140, height = 36,
                        marginTop = 16,
                        variant = "secondary",
                        borderRadius = 8,
                        onClick = function()
                            ShopUI.Close()
                        end,
                    },
                },
            },
        },
    }

    -- 查找引用
    goldLabel_ = root_:FindById("shopGoldLabel")
    itemsContainer_ = root_:FindById("shopItemsGrid")
    titleLabel_ = root_:FindById("shopTitle")
    subtitleLabel_ = root_:FindById("shopSubtitle")
    buyTabBtn_ = root_:FindById("shopBuyTab")
    sellTabBtn_ = root_:FindById("shopSellTab")
    forgeTabBtn_ = root_:FindById("shopForgeTab")

    detailPanel_ = root_:FindById("shopDetailPanel")
    detailNameLabel_ = root_:FindById("sellDetailName")
    detailRarityLabel_ = root_:FindById("sellDetailRarity")
    detailDescLabel_ = root_:FindById("sellDetailDesc")
    detailAffixContainer_ = root_:FindById("sellDetailAffixes")
    detailPriceLabel_ = root_:FindById("sellDetailPrice")
    sellConfirmBtn_ = root_:FindById("sellConfirmBtn")

    return root_
end

-- ============================================================================
-- 显示 / 隐藏
-- ============================================================================

function ShopUI.Show()
    if not root_ then return end
    isOpen_ = true

    -- 显示鼠标
    input.mouseMode = MM_ABSOLUTE
    input.mouseVisible = true

    -- 重置为购买模式
    mode_ = "buy"
    selectedSellUID_ = nil
    forgeSelectedUID_ = nil
    setTabActive(buyTabBtn_, true)
    setTabActive(sellTabBtn_, false)
    setTabActive(forgeTabBtn_, false)
    if titleLabel_ then titleLabel_:SetText("嗡摩佬的商店") end
    if subtitleLabel_ then subtitleLabel_:SetText("选购武器和法器") end
    if detailPanel_ then detailPanel_:Hide() end

    -- 更新金币
    if goldLabel_ then
        goldLabel_:SetText("💰 " .. GameManager.GetGold())
    end

    -- 构建武器列表
    buildBuyCards()

    GameManager.SetState(GameConfig.States.SHOP)
    root_:Show()
    print("[Shop] 商店已打开")
end

function ShopUI.Close()
    if not root_ then return end
    isOpen_ = false
    selectedSellUID_ = nil
    root_:Hide()

    -- 恢复鼠标和游戏状态
    input.mouseMode = MM_RELATIVE
    input.mouseVisible = false
    GameManager.SetState(GameConfig.States.PLAYING)

    if onClose_ then onClose_() end
    print("[Shop] 商店已关闭")
end

function ShopUI.IsOpen()
    return isOpen_
end

function ShopUI.GetRoot()
    return root_
end

-- ============================================================================
-- 更新（ESC关闭）
-- ============================================================================

---@param dt number
function ShopUI.Update(dt)
    if not isOpen_ then return end
    if input:GetKeyPress(KEY_ESCAPE) then
        ShopUI.Close()
    end
end

-- ============================================================================
-- 回调
-- ============================================================================

---@param cb function
function ShopUI.OnClose(cb)
    onClose_ = cb
end

return ShopUI
