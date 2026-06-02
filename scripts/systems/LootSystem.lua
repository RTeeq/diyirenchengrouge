-- ============================================================================
-- LootSystem.lua — 世界掉落物管理
-- 敌人死亡后在世界中生成3D掉落物节点，浮动动画 + 自动拾取
-- ============================================================================

local GameConfig = require("config.GameConfig")
local RarityData = require("data.RarityData")
local LootTables = require("data.LootTables")
local ItemFactory = require("systems.ItemFactory")

local LootSystem = {}

---@type Scene
local scene_ = nil
local getPlayerPos_ = nil   -- function(): Vector3
local onPickup_ = nil       -- function(itemInstance)

local drops_ = {}            -- { [id] = dropData }
local dropCounter_ = 0
local PICKUP_RANGE = 2.5     -- 自动拾取半径（米）
local DROP_LIFETIME = 30.0   -- 掉落物存活时间（秒）
local BOB_SPEED = 3.0        -- 浮动频率
local BOB_HEIGHT = 0.3       -- 浮动幅度
local SPAWN_Y_OFFSET = 0.8   -- 生成高度偏移

-- 品级对应模型缩放（越稀有越大/越醒目）
local RARITY_SCALE = {
    [1] = 0.25,  -- 普通
    [2] = 0.30,  -- 优秀
    [3] = 0.35,  -- 稀有
    [4] = 0.40,  -- 史诗
    [5] = 0.50,  -- 传说
}

-- 分类对应模型
local CATEGORY_MODEL = {
    weapon    = "Models/Box.mdl",
    equipment = "Models/Sphere.mdl",
    item      = "Models/Cylinder.mdl",
}

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化掉落系统
---@param scn Scene
---@param getPos function 获取玩家位置的回调
function LootSystem.Init(scn, getPos)
    scene_ = scn
    getPlayerPos_ = getPos
    drops_ = {}
    dropCounter_ = 0
    print("[LootSystem] 初始化完成")
end

--- 设置拾取回调
---@param callback function(itemInstance)
function LootSystem.OnPickup(callback)
    onPickup_ = callback
end

function LootSystem.Reset()
    -- 清除所有掉落物节点
    for id, drop in pairs(drops_) do
        if drop.node then
            drop.node:Remove()
        end
    end
    drops_ = {}
    dropCounter_ = 0
end

-- ============================================================================
-- 掉落物生成
-- ============================================================================

--- 在指定位置生成一个掉落物
---@param position Vector3 世界位置
---@param itemInstance table 物品实例（来自ItemFactory）
function LootSystem.SpawnDrop(position, itemInstance)
    if not scene_ or not itemInstance then return end

    dropCounter_ = dropCounter_ + 1
    local id = "drop_" .. dropCounter_

    -- 创建节点
    local node = scene_:CreateChild("LootDrop_" .. id)
    local spawnPos = Vector3(position.x, position.y + SPAWN_Y_OFFSET, position.z)
    node.position = spawnPos

    -- 模型
    local model = node:CreateComponent("StaticModel")
    local mdlPath = CATEGORY_MODEL[itemInstance.category] or CATEGORY_MODEL.item
    model:SetModel(cache:GetResource("Model", mdlPath))

    -- 材质（品级颜色）
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    local clr = RarityData.GetRarityColor(itemInstance.rarity or 1)
    mat:SetShaderParameter("MatDiffColor", Variant(Color(clr[1]/255, clr[2]/255, clr[3]/255, 1.0)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(clr[1]/510, clr[2]/510, clr[3]/510, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.3))
    mat:SetShaderParameter("Metallic", Variant(0.6))
    model:SetMaterial(mat)

    -- 缩放
    local scale = RARITY_SCALE[itemInstance.rarity] or 0.25
    node:SetScale(Vector3(scale, scale, scale))

    -- 光照（高品级发光）
    if itemInstance.rarity >= 3 then
        local light = node:CreateComponent("Light")
        light.lightType = LIGHT_POINT
        light.castShadows = false
        light.color = Color(clr[1]/255, clr[2]/255, clr[3]/255, 1.0)
        light.range = 2.0 + itemInstance.rarity * 0.5
        light.brightness = 0.5 + itemInstance.rarity * 0.2
    end

    -- 记录掉落数据
    drops_[id] = {
        node        = node,
        item        = itemInstance,
        baseY       = spawnPos.y,
        age         = 0,
        bobPhase    = math.random() * 6.28,
    }

    local rarityName = RarityData.GetRarityName(itemInstance.rarity or 1)
    print("[LootSystem] 生成掉落物: " .. (itemInstance.baseId or "?")
        .. " [" .. rarityName .. "] at ("
        .. string.format("%.1f, %.1f, %.1f", position.x, position.y, position.z) .. ")")
end

--- 尝试从敌人死亡生成掉落
---@param enemyType string
---@param enemyLevel number
---@param isBoss boolean
---@param position Vector3 敌人死亡位置
---@return boolean 是否产生了掉落
function LootSystem.TryDropFromEnemy(enemyType, enemyLevel, isBoss, position)
    local rollResult = LootTables.Roll(enemyType, enemyLevel, isBoss)
    if not rollResult then return false end

    -- 使用 ItemFactory 创建物品实例
    local item = ItemFactory.CreateFromDrop(
        rollResult.baseId,
        rollResult.category,
        enemyLevel,
        enemyType,
        rollResult.minRarity
    )

    -- 随机偏移位置，避免重叠
    local offset = Vector3(
        (math.random() - 0.5) * 1.0,
        0,
        (math.random() - 0.5) * 1.0
    )
    local dropPos = Vector3(position.x + offset.x, position.y, position.z + offset.z)

    LootSystem.SpawnDrop(dropPos, item)
    return true
end

-- ============================================================================
-- 更新（浮动动画 + 拾取检测）
-- ============================================================================

function LootSystem.Update(dt)
    if not getPlayerPos_ then return end

    local playerPos = getPlayerPos_()
    if not playerPos then return end

    local toRemove = {}

    for id, drop in pairs(drops_) do
        drop.age = drop.age + dt

        -- 超时移除
        if drop.age > DROP_LIFETIME then
            -- 最后3秒闪烁
            if drop.node then
                drop.node:Remove()
            end
            table.insert(toRemove, id)
        else
            -- 浮动动画
            if drop.node then
                local bobY = drop.baseY + math.sin(drop.bobPhase + drop.age * BOB_SPEED) * BOB_HEIGHT
                local pos = drop.node.position
                drop.node.position = Vector3(pos.x, bobY, pos.z)

                -- 旋转
                local rot = drop.node.rotation
                drop.node:SetRotation(Quaternion(dt * 90, Vector3.UP) * rot)

                -- 最后5秒闪烁（通过缩放抖动）
                if drop.age > DROP_LIFETIME - 5.0 then
                    local blink = math.sin(drop.age * 10) > 0
                    drop.node:SetEnabled(blink)
                end

                -- 拾取检测
                local dx = pos.x - playerPos.x
                local dz = pos.z - playerPos.z
                local distSq = dx * dx + dz * dz
                if distSq < PICKUP_RANGE * PICKUP_RANGE then
                    -- 拾取
                    if onPickup_ then
                        onPickup_(drop.item)
                    end
                    drop.node:Remove()
                    table.insert(toRemove, id)
                    local rarityName = RarityData.GetRarityName(drop.item.rarity or 1)
                    print("[LootSystem] 拾取: " .. (drop.item.baseId or "?") .. " [" .. rarityName .. "]")
                end
            else
                table.insert(toRemove, id)
            end
        end
    end

    -- 清除已移除的掉落物
    for _, id in ipairs(toRemove) do
        drops_[id] = nil
    end
end

--- 获取当前掉落物数量
---@return number
function LootSystem.GetDropCount()
    local count = 0
    for _ in pairs(drops_) do count = count + 1 end
    return count
end

return LootSystem
