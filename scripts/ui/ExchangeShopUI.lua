-- ============================================================================
-- ExchangeShopUI.lua — 兑换商店
-- 货币兑换 / 稀有武器兑换 / Boss装备兑换
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local RarityData = require("data.RarityData")
local UI = require("urhox-libs/UI")
local UIHelper = require("ui.UIHelper")

local ExchangeShopUI = {}

-- UI 引用
local root_ = nil
local isOpen_ = false
local onClose_ = nil

-- 标签页
local mode_ = "currency" -- "currency" | "weapon" | "equipment"
local currencyTabBtn_ = nil
local weaponTabBtn_ = nil
local equipTabBtn_ = nil
local titleLabel_ = nil
local subtitleLabel_ = nil
local goldLabel_ = nil
local crystalLabel_ = nil
local contentArea_ = nil

-- 依赖注入
---@type table
local InventorySystem_ = nil

-- ============================================================================
-- 配置缓存
-- ============================================================================

local CFG = GameConfig.ExchangeShop or {}
local GOLD_PER_CRYSTAL  = CFG.GoldPerCrystal or 10
local CRYSTAL_PER_GOLD  = CFG.CrystalPerGold or 8
local GOLD_PRESETS      = CFG.GoldPresets or { 100, 500, 1000 }
local CRYSTAL_PRESETS   = CFG.CrystalPresets or { 10, 50, 100 }
local RARE_WEAPON_COSTS = CFG.RareWeaponCosts or { [3]=50, [4]=150, [5]=500 }
local EQUIP_COSTS       = CFG.EquipmentCosts or {}

-- ============================================================================
-- 标签页样式
-- ============================================================================

local function setTabActive(btn, active)
    if not btn then return end
    if active then
        btn:SetStyle({ backgroundColor = { 80, 200, 180, 220 }, fontColor = { 10, 20, 20, 255 } })
    else
        btn:SetStyle({ backgroundColor = { 40, 50, 60, 200 }, fontColor = { 160, 180, 180, 200 } })
    end
end

-- ============================================================================
-- 更新顶部货币显示
-- ============================================================================

local function refreshCurrency()
    if goldLabel_ then
        goldLabel_:SetText("💰 " .. GameManager.GetGold())
    end
    if crystalLabel_ then
        crystalLabel_:SetText("💎 " .. GameManager.GetCrystal())
    end
end

-- ============================================================================
-- 通知 & 音效
-- ============================================================================

local function notify(msg, color)
    local ok, HUD = pcall(require, "ui.HUD")
    if ok and HUD and HUD.ShowNotification then
        HUD.ShowNotification(msg, color or { 255, 255, 255, 255 })
    end
end

local function playSound()
    local ok, AM = pcall(require, "core.AudioManager")
    if ok and AM and AM.PlayItemPickup then AM.PlayItemPickup() end
end

-- ============================================================================
-- 前向声明
-- ============================================================================

local buildCurrencyContent
local buildWeaponContent
local buildEquipmentContent

-- ============================================================================
-- 标签页切换
-- ============================================================================

local function switchMode(newMode)
    if mode_ == newMode then return end
    mode_ = newMode

    setTabActive(currencyTabBtn_, mode_ == "currency")
    setTabActive(weaponTabBtn_,   mode_ == "weapon")
    setTabActive(equipTabBtn_,    mode_ == "equipment")

    if mode_ == "currency" then
        if titleLabel_ then titleLabel_:SetText("货币兑换") end
        if subtitleLabel_ then subtitleLabel_:SetText("金币与水晶互相转换") end
        buildCurrencyContent()
    elseif mode_ == "weapon" then
        if titleLabel_ then titleLabel_:SetText("稀有武器兑换") end
        if subtitleLabel_ then subtitleLabel_:SetText("消耗水晶获取指定品级武器") end
        buildWeaponContent()
    else
        if titleLabel_ then titleLabel_:SetText("装备兑换") end
        if subtitleLabel_ then subtitleLabel_:SetText("消耗水晶获取 Boss 装备") end
        buildEquipmentContent()
    end
end

-- ============================================================================
-- Tab 1: 货币兑换
-- ============================================================================

buildCurrencyContent = function()
    if not contentArea_ then return end
    UIHelper.DestroyChildren(contentArea_)

    local currentGold = GameManager.GetGold()
    local currentCrystal = GameManager.GetCrystal()

    -- ── 金币 → 水晶 ──
    contentArea_:AddChild(UI.Panel {
        width = "100%",
        backgroundColor = { 30, 28, 42, 220 },
        borderRadius = 10,
        borderWidth = 1,
        borderColor = { 255, 220, 80, 100 },
        padding = { 16, 14 },
        marginBottom = 14,
        children = {
            UI.Label {
                text = "💰 金币 → 💎 水晶",
                fontSize = 16,
                fontWeight = "bold",
                fontColor = { 255, 230, 140, 255 },
                marginBottom = 4,
            },
            UI.Label {
                text = "汇率: " .. GOLD_PER_CRYSTAL .. " 金币 = 1 水晶",
                fontSize = 11,
                fontColor = { 160, 160, 180, 180 },
                marginBottom = 12,
            },
            UI.Panel {
                flexDirection = "row",
                flexWrap = "wrap",
                justifyContent = "center",
                children = (function()
                    local btns = {}
                    for _, amount in ipairs(GOLD_PRESETS) do
                        local crystalGet = math.floor(amount / GOLD_PER_CRYSTAL)
                        local canAfford = currentGold >= amount
                        local capturedAmt = amount
                        table.insert(btns, UI.Panel {
                            alignItems = "center",
                            margin = 5,
                            children = {
                                UI.Button {
                                    text = "💰" .. amount .. " → 💎" .. crystalGet,
                                    fontSize = 11,
                                    width = 140,
                                    height = 34,
                                    variant = canAfford and "primary" or "secondary",
                                    borderRadius = 8,
                                    disabled = not canAfford,
                                    onClick = function()
                                        ExchangeShopUI.DoGoldToCrystal(capturedAmt)
                                    end,
                                },
                            },
                        })
                    end
                    -- 全部兑换
                    local maxConvert = math.floor(currentGold / GOLD_PER_CRYSTAL) * GOLD_PER_CRYSTAL
                    if maxConvert > 0 then
                        local maxCrystal = math.floor(maxConvert / GOLD_PER_CRYSTAL)
                        table.insert(btns, UI.Panel {
                            alignItems = "center",
                            margin = 5,
                            children = {
                                UI.Button {
                                    text = "全部 → 💎" .. maxCrystal,
                                    fontSize = 11,
                                    width = 140,
                                    height = 34,
                                    variant = "warning",
                                    borderRadius = 8,
                                    onClick = function()
                                        ExchangeShopUI.DoGoldToCrystal(maxConvert)
                                    end,
                                },
                            },
                        })
                    end
                    return btns
                end)(),
            },
        },
    })

    -- ── 水晶 → 金币 ──
    contentArea_:AddChild(UI.Panel {
        width = "100%",
        backgroundColor = { 28, 30, 48, 220 },
        borderRadius = 10,
        borderWidth = 1,
        borderColor = { 100, 180, 255, 100 },
        padding = { 16, 14 },
        children = {
            UI.Label {
                text = "💎 水晶 → 💰 金币",
                fontSize = 16,
                fontWeight = "bold",
                fontColor = { 140, 200, 255, 255 },
                marginBottom = 4,
            },
            UI.Label {
                text = "汇率: 1 水晶 = " .. CRYSTAL_PER_GOLD .. " 金币",
                fontSize = 11,
                fontColor = { 160, 160, 180, 180 },
                marginBottom = 12,
            },
            UI.Panel {
                flexDirection = "row",
                flexWrap = "wrap",
                justifyContent = "center",
                children = (function()
                    local btns = {}
                    for _, amount in ipairs(CRYSTAL_PRESETS) do
                        local goldGet = amount * CRYSTAL_PER_GOLD
                        local canAfford = currentCrystal >= amount
                        local capturedAmt = amount
                        table.insert(btns, UI.Panel {
                            alignItems = "center",
                            margin = 5,
                            children = {
                                UI.Button {
                                    text = "💎" .. amount .. " → 💰" .. goldGet,
                                    fontSize = 11,
                                    width = 140,
                                    height = 34,
                                    variant = canAfford and "primary" or "secondary",
                                    borderRadius = 8,
                                    disabled = not canAfford,
                                    onClick = function()
                                        ExchangeShopUI.DoCrystalToGold(capturedAmt)
                                    end,
                                },
                            },
                        })
                    end
                    -- 全部兑换
                    if currentCrystal > 0 then
                        local maxGold = currentCrystal * CRYSTAL_PER_GOLD
                        table.insert(btns, UI.Panel {
                            alignItems = "center",
                            margin = 5,
                            children = {
                                UI.Button {
                                    text = "全部 → 💰" .. maxGold,
                                    fontSize = 11,
                                    width = 140,
                                    height = 34,
                                    variant = "warning",
                                    borderRadius = 8,
                                    onClick = function()
                                        ExchangeShopUI.DoCrystalToGold(currentCrystal)
                                    end,
                                },
                            },
                        })
                    end
                    return btns
                end)(),
            },
        },
    })
end

--- 执行金币→水晶
function ExchangeShopUI.DoGoldToCrystal(goldAmount)
    local crystalGet = math.floor(goldAmount / GOLD_PER_CRYSTAL)
    if crystalGet <= 0 then return end
    if not GameManager.SpendGold(goldAmount) then
        notify("金币不足！", { 255, 80, 80, 255 })
        return
    end
    GameManager.AddCrystal(crystalGet)
    playSound()
    notify("兑换成功: +" .. crystalGet .. " 水晶", { 100, 200, 255, 255 })
    refreshCurrency()
    buildCurrencyContent()
end

--- 执行水晶→金币
function ExchangeShopUI.DoCrystalToGold(crystalAmount)
    local goldGet = crystalAmount * CRYSTAL_PER_GOLD
    local current = GameManager.GetCrystal()
    if current < crystalAmount then
        notify("水晶不足！", { 255, 80, 80, 255 })
        return
    end
    -- 手动扣除水晶（GameManager 没有 SpendCrystal）
    GameManager.AddCrystal(-crystalAmount)
    GameManager.AddGold(goldGet)
    playSound()
    notify("兑换成功: +" .. goldGet .. " 金币", { 255, 220, 80, 255 })
    refreshCurrency()
    buildCurrencyContent()
end

-- ============================================================================
-- Tab 2: 稀有武器兑换
-- ============================================================================

buildWeaponContent = function()
    if not contentArea_ then return end
    UIHelper.DestroyChildren(contentArea_)

    local currentCrystal = GameManager.GetCrystal()

    -- 按品级排序
    local rarities = {}
    for r, cost in pairs(RARE_WEAPON_COSTS) do
        table.insert(rarities, { rarity = r, cost = cost })
    end
    table.sort(rarities, function(a, b) return a.rarity < b.rarity end)

    for _, entry in ipairs(rarities) do
        local r = entry.rarity
        local cost = entry.cost
        local rarityColor = RarityData.GetRarityColor(r)
        local rarityName = RarityData.GetRarityName(r)
        local canAfford = currentCrystal >= cost

        contentArea_:AddChild(UI.Panel {
            width = "100%",
            flexDirection = "row",
            alignItems = "center",
            backgroundColor = { 30, 28, 42, 220 },
            borderRadius = 10,
            borderWidth = 2,
            borderColor = { rarityColor[1], rarityColor[2], rarityColor[3], 120 },
            padding = { 14, 12 },
            marginBottom = 10,
            children = {
                -- 品级图标
                UI.Panel {
                    width = 48, height = 48,
                    borderRadius = 24,
                    backgroundColor = { rarityColor[1], rarityColor[2], rarityColor[3], 40 },
                    justifyContent = "center",
                    alignItems = "center",
                    marginRight = 14,
                    children = {
                        UI.Label {
                            text = "🎁",
                            fontSize = 24,
                        },
                    },
                },
                -- 描述
                UI.Panel {
                    flexGrow = 1,
                    flexShrink = 1,
                    children = {
                        UI.Label {
                            text = rarityName .. "品质 · 随机武器",
                            fontSize = 14,
                            fontWeight = "bold",
                            fontColor = rarityColor,
                            marginBottom = 2,
                        },
                        UI.Label {
                            text = "随机获得一把" .. rarityName .. "品质武器，附带对应词条",
                            fontSize = 10,
                            fontColor = { 160, 160, 180, 180 },
                        },
                    },
                },
                -- 兑换按钮
                UI.Button {
                    text = "💎 " .. cost,
                    fontSize = 12,
                    fontWeight = "bold",
                    width = 90,
                    height = 36,
                    variant = canAfford and "primary" or "secondary",
                    borderRadius = 8,
                    disabled = not canAfford,
                    flexShrink = 0,
                    onClick = function()
                        ExchangeShopUI.DoWeaponExchange(r, cost)
                    end,
                },
            },
        })
    end

    -- 说明
    contentArea_:AddChild(UI.Label {
        text = "提示: 武器种类随机，品级保证不低于所选等级",
        fontSize = 10,
        fontColor = { 140, 140, 160, 140 },
        marginTop = 10,
        textAlign = "center",
    })
end

--- 执行稀有武器兑换
function ExchangeShopUI.DoWeaponExchange(rarity, cost)
    if not InventorySystem_ then
        notify("仓库未初始化", { 255, 80, 80, 255 })
        return
    end

    local currentCrystal = GameManager.GetCrystal()
    if currentCrystal < cost then
        notify("水晶不足！", { 255, 80, 80, 255 })
        return
    end

    -- 检查仓库容量
    if InventorySystem_.GetItemCount() >= 80 then
        notify("仓库已满！", { 255, 80, 80, 255 })
        return
    end

    -- 随机选择一把武器（排除铁剑）
    local candidates = {}
    for _, wid in ipairs(GameConfig.Weapons.Order) do
        if wid ~= "iron_sword" then
            table.insert(candidates, wid)
        end
    end
    if #candidates == 0 then return end

    local chosen = candidates[math.random(1, #candidates)]

    -- 扣水晶
    GameManager.AddCrystal(-cost)

    -- 创建物品
    local ItemFactory = require("systems.ItemFactory")
    local affixes = RarityData.RollAffixes(rarity)
    local item = ItemFactory.CreateFixed(chosen, "weapon", rarity, affixes)
    item.source = "exchange"
    InventorySystem_.AddItem(item)

    -- 通知
    local wCfg = GameConfig.Weapons[chosen]
    local rarityName = RarityData.GetRarityName(rarity)
    local weaponName = wCfg and wCfg.name or chosen
    local weaponIcon = wCfg and wCfg.icon or "?"
    playSound()
    notify(weaponIcon .. " 获得" .. rarityName .. " " .. weaponName .. "！",
        RarityData.GetRarityColor(rarity))

    -- 刷新武器系统
    local ok, WS = pcall(require, "combat.WeaponSystem")
    if ok and WS and WS.RefreshWeapons then WS.RefreshWeapons() end

    refreshCurrency()
    buildWeaponContent()
end

-- ============================================================================
-- Tab 3: 装备兑换
-- ============================================================================

buildEquipmentContent = function()
    if not contentArea_ then return end
    UIHelper.DestroyChildren(contentArea_)

    local currentCrystal = GameManager.GetCrystal()

    for _, equipId in ipairs(GameConfig.EquipmentOrder or {}) do
        local eCfg = GameConfig.Equipment[equipId]
        local eCost = EQUIP_COSTS[equipId]
        if not eCfg or not eCost then goto continue end

        local cost = eCost.crystal
        local rarity = eCost.rarity or 3
        local rarityColor = RarityData.GetRarityColor(rarity)
        local rarityName = RarityData.GetRarityName(rarity)
        local canAfford = currentCrystal >= cost
        local capturedId = equipId
        local capturedCost = cost
        local capturedRarity = rarity

        contentArea_:AddChild(UI.Panel {
            width = "100%",
            flexDirection = "row",
            alignItems = "center",
            backgroundColor = { 30, 28, 42, 220 },
            borderRadius = 10,
            borderWidth = 2,
            borderColor = { rarityColor[1], rarityColor[2], rarityColor[3], 120 },
            padding = { 14, 12 },
            marginBottom = 10,
            children = {
                -- 图标
                UI.Panel {
                    width = 48, height = 48,
                    borderRadius = 24,
                    backgroundColor = { rarityColor[1], rarityColor[2], rarityColor[3], 40 },
                    justifyContent = "center",
                    alignItems = "center",
                    marginRight = 14,
                    children = {
                        UI.Label {
                            text = eCfg.icon or "?",
                            fontSize = 24,
                        },
                    },
                },
                -- 描述
                UI.Panel {
                    flexGrow = 1,
                    flexShrink = 1,
                    children = {
                        UI.Label {
                            text = eCfg.name,
                            fontSize = 14,
                            fontWeight = "bold",
                            fontColor = rarityColor,
                            marginBottom = 2,
                        },
                        UI.Label {
                            text = rarityName .. " · " .. (eCfg.desc or ""),
                            fontSize = 10,
                            fontColor = { 160, 160, 180, 180 },
                            marginBottom = 2,
                        },
                        -- 被动属性
                        UI.Label {
                            text = (function()
                                if not eCfg.passive then return "" end
                                local parts = {}
                                if eCfg.passive.maxHP then table.insert(parts, "生命+" .. eCfg.passive.maxHP) end
                                if eCfg.passive.damagePct then table.insert(parts, "伤害+" .. eCfg.passive.damagePct .. "%") end
                                if eCfg.passive.cooldownPct then table.insert(parts, "冷却-" .. eCfg.passive.cooldownPct .. "%") end
                                if eCfg.passive.atkSpdPct then table.insert(parts, "攻速+" .. eCfg.passive.atkSpdPct .. "%") end
                                if eCfg.passive.moveSpdPct then table.insert(parts, "移速+" .. eCfg.passive.moveSpdPct .. "%") end
                                if eCfg.passive.rangePct then table.insert(parts, "范围+" .. eCfg.passive.rangePct .. "%") end
                                return table.concat(parts, "  ")
                            end)(),
                            fontSize = 10,
                            fontColor = { 180, 220, 140, 200 },
                        },
                    },
                },
                -- 兑换按钮
                UI.Button {
                    text = "💎 " .. cost,
                    fontSize = 12,
                    fontWeight = "bold",
                    width = 90,
                    height = 36,
                    variant = canAfford and "primary" or "secondary",
                    borderRadius = 8,
                    disabled = not canAfford,
                    flexShrink = 0,
                    onClick = function()
                        ExchangeShopUI.DoEquipmentExchange(capturedId, capturedCost, capturedRarity)
                    end,
                },
            },
        })

        ::continue::
    end

    -- 说明
    contentArea_:AddChild(UI.Label {
        text = "提示: 装备可重复购买，品级固定，词条随机",
        fontSize = 10,
        fontColor = { 140, 140, 160, 140 },
        marginTop = 10,
        textAlign = "center",
    })
end

--- 执行装备兑换
function ExchangeShopUI.DoEquipmentExchange(equipId, cost, rarity)
    if not InventorySystem_ then
        notify("仓库未初始化", { 255, 80, 80, 255 })
        return
    end

    local currentCrystal = GameManager.GetCrystal()
    if currentCrystal < cost then
        notify("水晶不足！", { 255, 80, 80, 255 })
        return
    end

    if InventorySystem_.GetItemCount() >= 80 then
        notify("仓库已满！", { 255, 80, 80, 255 })
        return
    end

    GameManager.AddCrystal(-cost)

    local ItemFactory = require("systems.ItemFactory")
    local affixes = RarityData.RollAffixes(rarity)
    local item = ItemFactory.CreateFixed(equipId, "equipment", rarity, affixes)
    item.source = "exchange"
    InventorySystem_.AddItem(item)

    local eCfg = GameConfig.Equipment[equipId]
    local rarityName = RarityData.GetRarityName(rarity)
    playSound()
    notify((eCfg and eCfg.icon or "?") .. " 获得" .. rarityName .. " " ..
        (eCfg and eCfg.name or equipId) .. "！",
        RarityData.GetRarityColor(rarity))

    refreshCurrency()
    buildEquipmentContent()
end

-- ============================================================================
-- 依赖注入
-- ============================================================================

---@param invSys table InventorySystem 模块
function ExchangeShopUI.SetInventorySystem(invSys)
    InventorySystem_ = invSys
end

-- ============================================================================
-- 初始化
-- ============================================================================

function ExchangeShopUI.Init()
    root_ = UI.Panel {
        id = "exchangeShopOverlay",
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
                maxWidth = 680,
                maxHeight = "88%",
                backgroundColor = { 16, 20, 28, 245 },
                borderRadius = 14,
                borderWidth = 2,
                borderColor = { 60, 180, 160, 180 },
                padding = { 20, 24 },
                children = {
                    -- 标题
                    UI.Label {
                        id = "exchTitle",
                        text = "货币兑换",
                        fontSize = 24,
                        fontWeight = "bold",
                        fontColor = { 80, 230, 200, 255 },
                        marginBottom = 2,
                    },
                    UI.Label {
                        id = "exchSubtitle",
                        text = "金币与水晶互相转换",
                        fontSize = 12,
                        fontColor = { 140, 170, 170, 160 },
                        marginBottom = 10,
                    },

                    -- 标签页栏
                    UI.Panel {
                        flexDirection = "row",
                        justifyContent = "center",
                        marginBottom = 12,
                        children = {
                            UI.Button {
                                id = "exchCurrencyTab",
                                text = "货币兑换",
                                fontSize = 12,
                                fontWeight = "bold",
                                width = 100, height = 30,
                                borderRadius = 8,
                                marginRight = 6,
                                onClick = function() switchMode("currency") end,
                            },
                            UI.Button {
                                id = "exchWeaponTab",
                                text = "稀有武器",
                                fontSize = 12,
                                fontWeight = "bold",
                                width = 100, height = 30,
                                borderRadius = 8,
                                marginRight = 6,
                                onClick = function() switchMode("weapon") end,
                            },
                            UI.Button {
                                id = "exchEquipTab",
                                text = "装备兑换",
                                fontSize = 12,
                                fontWeight = "bold",
                                width = 100, height = 30,
                                borderRadius = 8,
                                onClick = function() switchMode("equipment") end,
                            },
                        },
                    },

                    -- 货币显示
                    UI.Panel {
                        flexDirection = "row",
                        justifyContent = "center",
                        marginBottom = 14,
                        children = {
                            UI.Label {
                                id = "exchGoldLabel",
                                text = "💰 0",
                                fontSize = 16,
                                fontWeight = "bold",
                                fontColor = { 255, 230, 140, 255 },
                                marginRight = 24,
                            },
                            UI.Label {
                                id = "exchCrystalLabel",
                                text = "💎 0",
                                fontSize = 16,
                                fontWeight = "bold",
                                fontColor = { 140, 200, 255, 255 },
                            },
                        },
                    },

                    -- 主内容（滚动）
                    UI.ScrollView {
                        flexGrow = 1,
                        flexShrink = 1,
                        width = "100%",
                        children = {
                            UI.Panel {
                                id = "exchContent",
                                width = "100%",
                            },
                        },
                    },

                    -- 关闭按钮
                    UI.Button {
                        text = "关闭",
                        fontSize = 14,
                        width = 140, height = 36,
                        marginTop = 16,
                        variant = "secondary",
                        borderRadius = 8,
                        onClick = function()
                            ExchangeShopUI.Close()
                        end,
                    },
                },
            },
        },
    }

    -- 查找引用
    titleLabel_     = root_:FindById("exchTitle")
    subtitleLabel_  = root_:FindById("exchSubtitle")
    goldLabel_      = root_:FindById("exchGoldLabel")
    crystalLabel_   = root_:FindById("exchCrystalLabel")
    contentArea_    = root_:FindById("exchContent")
    currencyTabBtn_ = root_:FindById("exchCurrencyTab")
    weaponTabBtn_   = root_:FindById("exchWeaponTab")
    equipTabBtn_    = root_:FindById("exchEquipTab")

    return root_
end

-- ============================================================================
-- 显示 / 隐藏
-- ============================================================================

function ExchangeShopUI.Show()
    if not root_ then return end
    isOpen_ = true

    input.mouseMode = MM_ABSOLUTE
    input.mouseVisible = true

    -- 重置为货币兑换
    mode_ = "currency"
    setTabActive(currencyTabBtn_, true)
    setTabActive(weaponTabBtn_,   false)
    setTabActive(equipTabBtn_,    false)
    if titleLabel_ then titleLabel_:SetText("货币兑换") end
    if subtitleLabel_ then subtitleLabel_:SetText("金币与水晶互相转换") end

    refreshCurrency()
    buildCurrencyContent()

    GameManager.SetState(GameConfig.States.EXCHANGE_SHOP)
    root_:Show()
    print("[ExchangeShop] 兑换商店已打开")
end

function ExchangeShopUI.Close()
    if not root_ then return end
    isOpen_ = false
    root_:Hide()

    input.mouseMode = MM_RELATIVE
    input.mouseVisible = false
    GameManager.SetState(GameConfig.States.PLAYING)

    if onClose_ then onClose_() end
    print("[ExchangeShop] 兑换商店已关闭")
end

function ExchangeShopUI.IsOpen()
    return isOpen_
end

function ExchangeShopUI.GetRoot()
    return root_
end

-- ============================================================================
-- 更新（ESC 关闭）
-- ============================================================================

---@param dt number
function ExchangeShopUI.Update(dt)
    if not isOpen_ then return end
    if input:GetKeyPress(KEY_ESCAPE) then
        ExchangeShopUI.Close()
    end
end

-- ============================================================================
-- 回调
-- ============================================================================

---@param cb function
function ExchangeShopUI.OnClose(cb)
    onClose_ = cb
end

return ExchangeShopUI
