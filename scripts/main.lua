-- ============================================================================
-- main.lua — 入口文件
-- 第一人称三渲二解密游戏
-- ============================================================================

---@diagnostic disable-next-line: undefined-global
local sdk = sdk

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local FirstPersonController = require("core.FirstPersonController")
local InteractionSystem = require("core.InteractionSystem")
local SaveSystem = require("core.SaveSystem")
local AudioManager = require("core.AudioManager")
local VillageBuilder = require("world.VillageBuilder")
local NPCManager = require("world.NPCManager")
local ItemSpawner = require("world.ItemSpawner")
local QuestData = require("data.QuestData")
local DialogueUI = require("ui.DialogueUI")
local HUD = require("ui.HUD")
local DashHUD = require("ui.DashHUD")
local CharacterPanelUI = require("ui.CharacterPanelUI")
local InventorySystem = require("systems.InventorySystem")
local LootSystem = require("systems.LootSystem")
local MapUI = require("ui.MapUI")
local MenuUI = require("ui.MenuUI")
local GameEditor = require("editor.GameEditor")
local EditorDevTab = require("editor.EditorDevTab")
local PlayerHealth = require("combat.PlayerHealth")
local EnemyManager = require("combat.EnemyManager")
local WeaponSystem = require("combat.WeaponSystem")
local LevelSystem = require("combat.LevelSystem")
local XPOrbManager = require("combat.XPOrbManager")
local SkillSystem = require("combat.SkillSystem")
local AreaBossManager = require("combat.AreaBossManager")
local EquipmentSystem = require("combat.EquipmentSystem")
local KillBonusSystem = require("combat.KillBonusSystem")
local DebugCollision = require("debug.DebugCollision")
local LevelUpUI = require("ui.LevelUpUI")
local StartScreen = require("ui.StartScreen")
local ShopUI = require("ui.ShopUI")
local ExchangeShopUI = require("ui.ExchangeShopUI")
local SafeZoneSystem = require("world.SafeZoneSystem")
local ResultScreen = require("ui.ResultScreen")
local SettingsUI = require("ui.SettingsUI")
local MobileControls = require("ui.MobileControls")
local GamepadControls = require("ui.GamepadControls")
local DroneCamera = require("core.DroneCamera")
local TutorialUI = require("ui.TutorialUI")
local AwakeningSystem = require("systems.AwakeningSystem")
local DifficultySystem = require("systems.DifficultySystem")
local DifficultySelectUI = require("ui.DifficultySelectUI")
local SettlementUI = require("ui.SettlementUI")
local WeatherSkySystem = require("world.WeatherSkySystem")

-- UI 系统
local UI = require("urhox-libs/UI")
local Video = require("urhox-libs/Video")

---@type Scene
local scene_ = nil
local fpController_ = nil
local adVideoPanel_ = nil    -- 全屏 Rick Roll 视频覆盖层
local adVideoPlayer_ = nil   -- 视频播放器引用
local adSkipBtn_ = nil        -- 快速移动的跳过按钮
local adCountdownLabel_ = nil -- 倒计时标签
local adSkipElapsed_ = 0      -- 广告已播放时长（秒）
local adSkipX_ = 50           -- 跳过按钮当前位置
local adSkipY_ = 50
local adSkipDirX_ = 1         -- 移动方向
local adSkipDirY_ = 1
local AD_SKIP_DELAY = 30      -- 跳过按钮出现延迟（秒）
local AD_SKIP_BASE_SPEED = 200  -- 基础移动速度（像素/秒）
local AD_SKIP_ACCEL = 15       -- 每秒加速量（像素/秒²）

--- 广告复活共享逻辑：恢复满状态 + 保留进度
local function doAdRevive()
    adVideoPanel_:SetVisible(false)
    adVideoPlayer_:Stop()

    ResultScreen.Hide()

    -- 满状态恢复（满血 + 清debuff + 2秒无敌）
    PlayerHealth.Respawn()
    -- 清除武器冷却和活跃特效（保留武器/技能选择）
    WeaponSystem.ClearCooldowns()
    -- 清除技能冷却（保留技能解锁和等级）
    LevelSystem.ClearSkillCooldowns()
    -- 清除技能活跃视觉特效（保留技能解锁）
    SkillSystem.CleanupEffects()
    -- 范围秒杀附近敌人（给复活腾出安全空间）
    EnemyManager.AOEDamage(fpController_:GetPosition(), 8.0, 9999)

    GameManager.SetState(GameConfig.States.PLAYING)
    FirstPersonController.SetMouseRelative()
    HUD.ShowItemNotify("广告复活成功！满血回归")
    print("[Main] 广告复活成功（满状态恢复，保留进度）")
end

-- BGM 切换状态
local currentBGMState_ = "explore"  -- "explore"|"battle"|"dragon"|"ultimate"
local combatCooldown_ = 0           -- 脱战冷却计时（秒）
local COMBAT_COOLDOWN = 5.0         -- 脱战后多少秒切回探索BGM

-- 装备加成缓存（避免每帧重复计算）
local cachedHPBonus_ = -1     -- 上一帧的 totalHPBonus（-1 = 未初始化）
local cachedSpeedMult_ = -1   -- 上一帧的 speedMult

-- ============================================================================
-- 公共重置函数（避免代码重复）
-- ============================================================================

--- 重置所有游戏系统（保留 GameConfig 当前值）
local function resetAllSystems()
    GameManager.Reset()
    PlayerHealth.Init()
    EnemyManager.Reset()
    WeaponSystem.Reset()
    WeaponSystem.RefreshWeapons()
    SkillSystem.Reset()
    LevelSystem.Reset()
    XPOrbManager.Reset()
    AreaBossManager.Reset()
    EquipmentSystem.Reset()
    KillBonusSystem.Reset()
    SafeZoneSystem.Reset()
    InventorySystem.Reset()
    LootSystem.Reset()
    AwakeningSystem.Reset()
    DifficultySystem.Reset()
    -- AreaBossManager.SpawnAll() 不再在重置时调用
    -- 敌人将在出征开始时生成
    ItemSpawner.RespawnAll(scene_)
    NPCManager.SpawnAll(scene_)
    HUD.ResetTimer()
    -- 重新应用 GameConfig 到游戏系统（保证开发者面板修改生效）
    FirstPersonController.ApplyConfig()
    PlayerHealth.ApplyConfig()
    LevelSystem.ApplyConfig()
    -- 恢复晴天氛围
    WeatherSkySystem.ResetToDefault()
    -- 重置加成缓存
    cachedHPBonus_ = -1
    cachedSpeedMult_ = -1
end

--- 结算时重置角色系统（保留世界/金币/水晶/难度）+ 清除所有敌人
local function resetCharacterForSettlement()
    -- 清除所有敌人和战场遗留
    EnemyManager.Reset()
    AreaBossManager.Reset()
    XPOrbManager.Reset()
    LootSystem.Reset()
    -- 重置角色战斗系统（每次出征重新开始）
    PlayerHealth.Init()
    WeaponSystem.Reset()
    WeaponSystem.RefreshWeapons()
    SkillSystem.Reset()
    LevelSystem.Reset()
    EquipmentSystem.Reset()
    KillBonusSystem.Reset()
    -- InventorySystem / AwakeningSystem 不再重置：
    -- 背包道具、装备、觉醒点跟随存档永久保留（回安全区即锁定）
    -- 重新应用配置
    FirstPersonController.ApplyConfig()
    PlayerHealth.ApplyConfig()
    LevelSystem.ApplyConfig()
    -- 重置加成缓存
    cachedHPBonus_ = -1
    cachedSpeedMult_ = -1
    print("[Main] 结算重置：战斗系统已重置（资源保留）")
end

--- 重置并传送到出生点
local function resetAndTeleportToSpawn()
    resetAllSystems()
    local sp = GameConfig.Player.StartPosition
    fpController_:SetPosition(Vector3(sp.x, sp.y, sp.z))
end

--- 重置 → 进入游戏状态
local function resetAndStartPlaying()
    resetAndTeleportToSpawn()
    GameManager.SetState(GameConfig.States.PLAYING)
    FirstPersonController.SetMouseRelative()
    HUD.SetCrosshairVisible(true)
end

--- 重置 → 回到主菜单
local function resetAndReturnToMenu()
    resetAndTeleportToSpawn()
    StartScreen.Show()
    GameManager.SetState(GameConfig.States.MAIN_MENU)
    FirstPersonController.SetMouseAbsolute()
    HUD.SetCrosshairVisible(false)
end

-- 闪电特效状态
local lightningPanel_ = nil          -- 闪电白屏叠层
local lightningTimer_ = 0            -- 闪电特效倒计时
local lightningFlashes_ = 0          -- 剩余闪烁次数
local lightningPhase_ = "off"        -- "off"|"flash"|"dark"
local lightningPhaseDur_ = 0         -- 当前阶段剩余时间

-- 前向声明（函数在文件后半部分定义）
local triggerLightningEffect

-- ============================================================================
-- 引擎生命周期
-- ============================================================================

function Start()
    -- 0. 加载开发者面板保存的配置覆盖
    GameConfig.LoadOverrides()

    graphics.windowTitle = GameConfig.Title

    -- 1. 初始化 UI 系统
    UI.Init({
        fonts = {
            { family = "sans", weights = {
                normal = "Fonts/MiSans-Regular.ttf",
            } }
        },
        scale = UI.Scale.DEFAULT,
    })

    -- 2. 创建场景
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")

    -- 3. 构建村庄
    VillageBuilder.SetupLighting(scene_)

    -- 3.5 初始化天气/天空/氛围系统（接管 LightGroup 管理）
    WeatherSkySystem.Init(scene_)
    WeatherSkySystem.SetLightningCallback(function(flashes)
        triggerLightningEffect(flashes)
        AudioManager.PlayThunderStrike()
    end)

    VillageBuilder.Build(scene_)
    VillageBuilder.SetupPhysics(scene_)

    -- 4. 存档在选择槽位后加载（不再此处自动读取）

    -- 5. 生成NPC和物品
    NPCManager.SpawnAll(scene_)
    ItemSpawner.SpawnAll(scene_)

    -- 6. 创建第一人称控制器
    fpController_ = FirstPersonController.Create(scene_)

    -- 6.5. 初始化移动端虚拟控制
    MobileControls.Init()
    MobileControls.SetVisible(false)  -- 初始隐藏，进入PLAYING后根据模式显示

    -- 6.6. 初始化无人机相机
    DroneCamera.Init(scene_)

    -- 7. 初始化交互系统
    InteractionSystem.Init(scene_, fpController_:GetCameraNode())

    -- 8. 初始化音频系统
    AudioManager.Init(scene_)
    AudioManager.PlayBGM()

    -- 9. 初始化战斗系统
    PlayerHealth.Init()
    EnemyManager.Init(scene_,
        function() return fpController_:GetPosition() end,
        function() return fpController_:GetCameraNode() end
    )
    WeaponSystem.Init(scene_,
        function() return fpController_:GetPosition() end,
        function() return fpController_:GetCameraNode() end
    )
    WeaponSystem.RefreshWeapons()

    -- 9.3 技能系统初始化
    SkillSystem.Init(scene_,
        function() return fpController_:GetPosition() end,
        function() return fpController_:GetCameraNode() end
    )

    -- 9.5 升级系统初始化
    LevelSystem.Init()
    XPOrbManager.Init(scene_)

    -- 9.6 区域Boss + 装备系统
    AreaBossManager.Init(scene_, function() return fpController_:GetPosition() end)
    EquipmentSystem.Init(scene_, function() return fpController_:GetPosition() end)

    -- 9.6.1 仓库 + 掉落系统 + 觉醒系统 + 难度系统
    InventorySystem.Init()
    AwakeningSystem.Init()
    DifficultySystem.Init()
    GameManager.SetInventorySystem(InventorySystem)
    EquipmentSystem.SetInventorySystem(InventorySystem)
    ShopUI.SetInventorySystem(InventorySystem)
    ExchangeShopUI.SetInventorySystem(InventorySystem)
    LootSystem.Init(scene_, function() return fpController_:GetPosition() end)
    LootSystem.OnPickup(function(itemInstance)
        local added = InventorySystem.AddItem(itemInstance)
        if added then
            local RarityData = require("data.RarityData")
            local rarityName = RarityData.GetRarityName(itemInstance.rarity or 1)
            local name = itemInstance.baseId
            -- 尝试获取显示名
            if itemInstance.category == "weapon" then
                local w = GameConfig.Weapons[itemInstance.baseId]
                if w then name = w.name end
            elseif itemInstance.category == "equipment" then
                local eq = GameConfig.Equipment[itemInstance.baseId]
                if eq then name = eq.name end
            end
            HUD.ShowItemNotify("拾取: " .. name .. " [" .. rarityName .. "]")
            AudioManager.PlayItemPickup()
        else
            HUD.ShowItemNotify("仓库已满，无法拾取！")
        end
    end)
    -- 敌人死亡掉落回调
    EnemyManager.OnEnemyDeath(function(enemyData, deathPos)
        LootSystem.TryDropFromEnemy(
            enemyData.type,
            enemyData.monsterLvl or 1,
            enemyData.isBoss,
            deathPos
        )
    end)

    -- AreaBossManager.SpawnAll() 不再在启动时调用
    -- 敌人将在出征开始时生成（见 OnLeaveSafeZone 回调）

    -- 9.7 击杀加成系统
    KillBonusSystem.Init()

    -- 9.8 碰撞体调试可视化（初始隐藏）
    DebugCollision.Init(scene_)
    KillBonusSystem.SetPlayerPosGetter(function() return fpController_:GetPosition() end)

    -- 击杀里程碑通知
    KillBonusSystem.OnMilestone(function(tier, rangeMult, cdMult)
        local pct = tier * 2
        HUD.ShowItemNotify("⚔ 击杀加成 x" .. tier .. " (范围+" .. pct .. "% 冷却-" .. pct .. "%)")
    end)

    -- 被动技能解锁通知
    KillBonusSystem.OnPassiveUnlock(function(passiveId, passiveName)
        HUD.ShowItemNotify("🌟 解锁被动技能: " .. passiveName .. "!")
        AudioManager.PlayLevelUp()
    end)

    -- 区域Boss击杀回调
    AreaBossManager.OnBossDefeated(function(bossKey, bossName)
        print("[Main] 区域Boss被击败: " .. bossName)
    end)
    -- 装备拾取回调
    AreaBossManager.OnEquipPickup(function(equipId)
        EquipmentSystem.Equip(equipId)
        HUD.ShowEquipNotify(equipId)
        -- 同步maxHP被动
        local totalHPBonus = LevelSystem.GetMaxHPBonus() + EquipmentSystem.GetMaxHPBonus()
        PlayerHealth.SetMaxHPBonus(totalHPBonus)
        print("[Main] 拾取装备: " .. equipId)
    end)

    -- 10. 设置交互回调
    SetupInteractionCallbacks()

    -- 10. 初始化 UI 面板
    local dialoguePanel = DialogueUI.Init()
    local characterPanel = CharacterPanelUI.Init()
    local mapPanel = MapUI.Init()
    local pausePanel = MenuUI.Init()
    local levelUpPanel = LevelUpUI.Init()
    local shopPanel = ShopUI.Init()
    local exchangeShopPanel = ExchangeShopUI.Init()
    local expeditionSummaryPanel = SafeZoneSystem.CreateSummaryPanel()
    SafeZoneSystem.Init(scene_)
    local difficultySelectPanel = DifficultySelectUI.Init()
    local settlementPanel = SettlementUI.Init()
    local settingsPanel = SettingsUI.Init()
    local startPanel = StartScreen.Init()
    local resultPanel = ResultScreen.Init()
    local tutorialPanel = TutorialUI.Init()

    MapUI.SetController(fpController_)

    -- 11. 创建HUD（嵌入对话面板）
    local hudRoot = HUD.Init(dialoguePanel)

    -- 11.5a 闪现体力圆环 HUD
    DashHUD.Init()

    -- 11.5 创建"广告"视频覆盖层（Rick Roll）
    adVideoPlayer_ = Video.VideoPlayer {
        id = "adVideoPlayer",
        src = "video/【4K珍藏】诈骗神曲《Never Gonna Give You Up》！愿者上钩！.mp4",
        width = "100%",
        height = "100%",
        autoPlay = false,
        loop = false,
        objectFit = "contain",
        backgroundColor = {0, 0, 0, 255},
        pointerEvents = "none",  -- 禁止点击视频（防止暂停）

        onEnded = function(self)
            -- 视频播放完毕 → 执行复活逻辑
            doAdRevive()
        end,
    }

    -- 倒计时标签（固定右上角，30秒内显示）
    adCountdownLabel_ = UI.Label {
        id = "adCountdownLabel",
        text = "30s 后可跳过",
        fontSize = 13,
        fontColor = {255, 255, 255, 180},
        backgroundColor = {0, 0, 0, 100},
        borderRadius = 6,
        paddingLeft = 10, paddingRight = 10,
        paddingTop = 6, paddingBottom = 6,
        position = "absolute",
        top = 20,
        right = 20,
        visible = false,
    }

    -- 快速移动的跳过按钮（30秒后才显示，开始弹跳移动）
    adSkipBtn_ = UI.Button {
        id = "adSkipBtn",
        text = "跳过广告 >>",
        fontSize = 13,
        width = 100,
        height = 34,
        position = "absolute",
        top = 50,
        left = 50,
        visible = false,
        variant = "ghost",
        fontColor = {255, 255, 255, 180},
        backgroundColor = {0, 0, 0, 100},
        borderRadius = 6,
        onClick = function(self)
            -- 点中跳过按钮：执行复活
            doAdRevive()
        end,
    }

    adVideoPanel_ = UI.Panel {
        id = "adVideoOverlay",
        visible = false,
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = {0, 0, 0, 255},
        children = { adVideoPlayer_, adCountdownLabel_, adSkipBtn_ },
    }

    -- 11.8 闪电特效叠层（挑战Boss电闪雷鸣用）
    lightningPanel_ = UI.Panel {
        id = "lightningOverlay",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 255, 255, 255, 0 },
        visible = false,
        pointerEvents = "none",
    }

    -- 12. 构建总UI根（所有面板叠加）
    local uiRoot = UI.Panel {
        id = "rootContainer",
        width = "100%",
        height = "100%",
        children = {
            hudRoot,
            characterPanel,
            mapPanel,
            tutorialPanel,   -- 新手教程（在HUD上层，菜单下层）
            pausePanel,
            levelUpPanel,
            shopPanel,
            exchangeShopPanel,
            expeditionSummaryPanel,
            difficultySelectPanel,
            settlementPanel,
            resultPanel,
            lightningPanel_, -- 闪电特效层
            startPanel,      -- 开始界面在最上层
            settingsPanel,   -- 设置面板（覆盖在暂停/开始之上）
            adVideoPanel_,   -- 视频覆盖层在最顶层
        },
    }
    -- 12.5 初始化游戏编辑器（P 键调出）
    GameEditor.Init(scene_, uiRoot, fpController_)

    UI.SetRoot(uiRoot)

    -- 12.8 游戏初始状态：显示开始界面
    GameManager.SetState(GameConfig.States.MAIN_MENU)
    FirstPersonController.SetMouseAbsolute()
    HUD.SetCrosshairVisible(false)

    -- 存档选择回调：继续已有存档
    StartScreen.OnLoadSlot(function(slot)
        SaveSystem.SetActiveSlot(slot)
        SaveSystem.Load(slot)
        -- 加载存档后保存快照（存档里的状态即为上次结算的银行状态）
        GameManager.SaveSnapshot()
        resetAndTeleportToSpawn()
        StartScreen.Hide()
        GameManager.SetState(GameConfig.States.PLAYING)
        FirstPersonController.SetMouseRelative()
        HUD.SetCrosshairVisible(true)
        HUD.ResetTimer()
        print("[Main] 读取存档槽位 " .. slot .. " 进入游戏")
    end)

    -- 存档选择回调：新建存档
    StartScreen.OnNewSlot(function(slot)
        SaveSystem.SetActiveSlot(slot)
        resetAllSystems()
        -- 新建存档后保存初始快照（0 金币/0 水晶/初始背包）
        GameManager.SaveSnapshot()
        SaveSystem.Save()  -- 立即写入初始存档
        StartScreen.Hide()
        GameManager.SetState(GameConfig.States.PLAYING)
        FirstPersonController.SetMouseRelative()
        HUD.SetCrosshairVisible(true)
        HUD.ResetTimer()
        print("[Main] 新建存档槽位 " .. slot .. " 进入游戏")

        -- 新手教程
        if not TutorialUI.IsCompleted() then
            TutorialUI.Start(function()
                print("[Main] 新手教程完成")
            end)
        end
    end)

    -- 死亡界面回调：恢复到上次安全区结算的状态（不删除存档）
    ResultScreen.OnRestart(function()
        ResultScreen.Hide()
        if GameManager.HasSnapshot() then
            -- 恢复快照：金币/水晶/背包/觉醒点回到上次结算时的状态
            GameManager.RestoreSnapshot()
            -- 重置战斗系统
            resetCharacterForSettlement()
            -- 重置世界
            SafeZoneSystem.Reset()
            DifficultySystem.Reset()
            ItemSpawner.RespawnAll(scene_)
            NPCManager.SpawnAll(scene_)
            HUD.ResetTimer()
            WeatherSkySystem.ResetToDefault()
        else
            -- 无快照（首次出征即死亡），完全重置
            resetAllSystems()
        end
        -- 传送回出生点
        local sp = GameConfig.Player.StartPosition
        fpController_:SetPosition(Vector3(sp.x, sp.y, sp.z))
        GameManager.SetState(GameConfig.States.PLAYING)
        FirstPersonController.SetMouseRelative()
        HUD.SetCrosshairVisible(true)
        SaveSystem.Save()
        print("[Main] 死亡重开 → 恢复到上次结算状态")
    end)

    -- 13. 回调设置
    DialogueUI.OnDialogueEnd(function()
        HUD.SetCrosshairVisible(true)
        -- 嗡摩佬对话结束后打开商店
        if lastDialogueNpcId_ == GameConfig.NPCs.WENGMOLAO then
            ShopUI.Show()
        end
        lastDialogueNpcId_ = nil
    end)

    ShopUI.OnClose(function()
        HUD.SetCrosshairVisible(true)
    end)

    ExchangeShopUI.OnClose(function()
        HUD.SetCrosshairVisible(true)
    end)

    -- 离开安全区 → 弹出难度选择
    SafeZoneSystem.OnLeaveSafeZone(function()
        GameManager.SetState(GameConfig.States.PAUSED)
        FirstPersonController.SetMouseAbsolute()
        HUD.SetCrosshairVisible(false)
        DifficultySelectUI.Show(function(level)
            -- 难度选定，开始出征
            SafeZoneSystem.StartExpedition()
            -- 出征开始时生成敌人
            AreaBossManager.SpawnAll()
            ItemSpawner.RespawnAll(scene_)
            -- 切换天气氛围
            local atmCfg = DifficultySystem.GetConfig().atmosphere
            if atmCfg then
                WeatherSkySystem.SetAtmosphere(atmCfg)
            end
            GameManager.SetState(GameConfig.States.PLAYING)
            FirstPersonController.SetMouseRelative()
            HUD.SetCrosshairVisible(true)
            HUD.ShowItemNotify(DifficultySystem.GetIcon() .. " " .. DifficultySystem.GetName() .. " 难度出征开始！")
            print("[Main] 出征开始，难度: " .. DifficultySystem.GetName())
        end)
    end)

    -- 返回安全区 → 弹出结算确认
    SafeZoneSystem.OnReturnToSafeZone(function()
        GameManager.SetState(GameConfig.States.PAUSED)
        FirstPersonController.SetMouseAbsolute()
        HUD.SetCrosshairVisible(false)
        local expData = SafeZoneSystem.GetExpeditionData()
        SettlementUI.Show(expData, function()
            -- 选择结算
            local summary = SafeZoneSystem.EndExpedition()
            -- 发放出征奖励到 GameManager（唯一入账点）
            GameManager.AddGold(summary.goldEarned)
            GameManager.AddCrystal(summary.crystalEarned)
            -- 保存资源快照（银行存档：金币/水晶/背包/觉醒点锁定）
            -- 此后死亡只会回滚到这个快照，不会丢失已结算的资源
            GameManager.SaveSnapshot()
            -- 显示结算摘要
            SafeZoneSystem.ShowSummary(summary)
            -- 战斗系统重置（资源保留）
            resetCharacterForSettlement()
            -- 恢复晴天氛围
            WeatherSkySystem.ResetToDefault()
            -- 传送回出生点
            local sp = GameConfig.Player.StartPosition
            fpController_:SetPosition(Vector3(sp.x, sp.y, sp.z))
            -- 恢复游戏
            GameManager.SetState(GameConfig.States.PLAYING)
            FirstPersonController.SetMouseRelative()
            HUD.SetCrosshairVisible(true)
            SaveSystem.Save()
            print("[Main] 出征结算完成，资源已锁定")
        end, function()
            -- 拒绝结算 → 禁入安全区
            SafeZoneSystem.SetDeclinedSettlement(true)
            GameManager.SetState(GameConfig.States.PLAYING)
            FirstPersonController.SetMouseRelative()
            HUD.SetCrosshairVisible(true)
            HUD.ShowItemNotify("继续战斗！安全区暂时关闭")
            print("[Main] 玩家拒绝结算，继续出征")
        end)
    end)

    -- 推回回调：玩家拒绝结算后试图进入安全区
    SafeZoneSystem.OnPushBack(function(newPos)
        fpController_:SetPosition(newPos)
    end)

    MenuUI.OnNewGame(function()
        SaveSystem.Delete(SaveSystem.GetActiveSlot())
        resetAndTeleportToSpawn()
        SaveSystem.Save()
        print("[Main] 游戏重新开始")
    end)

    -- 暂停菜单：返回主页（回到开始界面）
    MenuUI.OnReturnHome(function()
        MenuUI.Resume()
        resetAndReturnToMenu()
        print("[Main] 暂停菜单 → 返回主页")
    end)

    -- 开发者面板：保存设置 & 重新开始（GameConfig 已在内存中修改，直接重置游戏状态）
    function DevRestartGame()
        GameEditor.Close()
        SaveSystem.Delete(SaveSystem.GetActiveSlot())
        resetAndStartPlaying()
        -- 显示修改摘要（2秒后自动消失）
        EditorDevTab.ShowChangeSummary(2)
        print("[Main] 开发者面板 → 保存设置 & 重新开始")
    end

    -- 暂停菜单：退出游戏（嵌入环境无法关闭窗口，回到主页）
    MenuUI.OnExitGame(function()
        SaveSystem.Save()
        MenuUI.Resume()
        resetAndReturnToMenu()
        print("[Main] 暂停菜单 → 退出游戏（回到主页）")
    end)

    -- 暂停菜单：脱离卡死（传送回出生点）
    MenuUI.OnUnstuck(function()
        local sp = GameConfig.Player.StartPosition
        fpController_:SetPosition(Vector3(sp.x, sp.y, sp.z))
        HUD.ShowItemNotify("已传送回出生点")
        print("[Main] 脱离卡死 → 传送回出生点")
    end)

    -- 开始界面：退出游戏（嵌入环境提示由宿主退出）
    StartScreen.OnExitGame(function()
        UI.Toast.Show("请使用右上角退出按钮关闭游戏", { variant = "info", duration = 2 })
    end)

    -- 升级系统回调
    LevelSystem.OnLevelUp(function(level, isSkillLevel)
        -- 暂停游戏，显示升级选择界面
        GameManager.SetState(GameConfig.States.LEVEL_UP)
        FirstPersonController.SetMouseAbsolute()
        HUD.SetCrosshairVisible(false)
        LevelUpUI.Show()
        -- 升级音效
        AudioManager.PlayLevelUp()
        -- 每次升级时同步最大血量加成
        PlayerHealth.SetMaxHPBonus(LevelSystem.GetMaxHPBonus())

        -- 每10级生成挑战龙Boss + 电闪雷鸣特效
        if level % 10 == 0 then
            EnemyManager.SpawnDragonBoss(fpController_:GetPosition(), level)
            HUD.ShowItemNotify("🐉 黑暗中国龙降临！等级 " .. level)
            -- 触发闪电特效 + 雷鸣音效
            triggerLightningEffect(4)
            AudioManager.PlayThunderStrike()
            -- 切换挑战Boss BGM
            AudioManager.PlayDragonBGM()
            currentBGMState_ = "dragon"
        end
    end)

    LevelUpUI.OnSelectionDone(function()
        -- 选完后恢复游戏
        GameManager.SetState(GameConfig.States.PLAYING)
        FirstPersonController.SetMouseRelative()
        HUD.SetCrosshairVisible(true)
        -- 同步属性加成
        PlayerHealth.SetMaxHPBonus(LevelSystem.GetMaxHPBonus())
    end)

    -- 龙Boss 击败回调（挑战Boss）：随机十倍属性加成 + 恢复BGM
    EnemyManager.OnDragonDefeated(function(dragonLevel)
        local attrs = GameConfig.Attributes
        local rewardMult = GameConfig.Enemies.Wave.BossRewardMult  -- 10
        local chosen = attrs[math.random(1, #attrs)]
        local bonuses = LevelSystem.GetBonuses()
        for i = 1, rewardMult do
            chosen.apply(bonuses)
        end
        PlayerHealth.SetMaxHPBonus(LevelSystem.GetMaxHPBonus())
        HUD.ShowItemNotify("🐉 挑战Boss击败! " .. chosen.icon .. chosen.name .. " x" .. rewardMult)
        print("[Main] 龙Boss(挑战Boss) 击败奖励: " .. chosen.name .. " x" .. rewardMult)
        -- 击败后切回探索BGM
        AudioManager.PlayBGM()
        currentBGMState_ = "explore"
    end)

    -- 终极Boss 生成通知：登场咆哮 + 最终战BGM
    EnemyManager.OnUltimateBossSpawned(function(monsterLevel)
        HUD.ShowItemNotify("👹 深渊魔王降临！怪物等级 " .. monsterLevel)
        -- 播放Boss登场咆哮音效
        AudioManager.PlayBossEntrance()
        -- 闪电特效烘托氛围
        triggerLightningEffect(3)
        -- 切换最终Boss BGM
        AudioManager.PlayUltimateBGM()
        currentBGMState_ = "ultimate"
    end)

    -- 终极Boss 击败回调：提升一级 + 恢复BGM
    EnemyManager.OnUltimateDefeated(function(bossLevel)
        local xpNeeded = LevelSystem.GetXPToNext() - LevelSystem.GetXP()
        LevelSystem.AddXP(xpNeeded)
        HUD.ShowItemNotify("👹 深渊魔王已被击败！获得一级提升！")
        print("[Main] 终极Boss 击败奖励：提升一级！怪物等级: " .. bossLevel)
        -- 击败后切回探索BGM
        AudioManager.PlayBGM()
        currentBGMState_ = "explore"
    end)

    -- 定时Boss 击败回调：提升一级
    EnemyManager.OnBossDefeated(function(bossLevel)
        local xpNeeded = LevelSystem.GetXPToNext() - LevelSystem.GetXP()
        LevelSystem.AddXP(xpNeeded)
        HUD.ShowItemNotify("Boss击败! 获得一级提升！")
        print("[Main] 定时Boss 击败奖励：提升一级！等级: " .. bossLevel)
    end)

    -- 战斗回调
    PlayerHealth.OnDamage(function(hp, maxHP, dmg)
        HUD.ShowDamageFlash()
        AudioManager.PlayPlayerHurt()
        SafeZoneSystem.RecordDamage(dmg)
    end)

    PlayerHealth.OnDeath(function()
        -- 死亡时自动退出无人机模式
        if DroneCamera.IsActive() then
            DroneCamera.Deactivate(fpController_)
        end
        -- 死亡时结束出征并清除拒绝结算状态
        if SafeZoneSystem.IsOnExpedition() then
            local summary = SafeZoneSystem.EndExpedition()
            -- 清除所有敌人
            EnemyManager.Reset()
            AreaBossManager.Reset()
            -- 死亡不发放奖励，出征数据清零
            print("[Main] 玩家死亡，出征失败，不发放奖励")
        end
        -- 恢复晴天氛围
        WeatherSkySystem.ResetToDefault()
        SafeZoneSystem.SetDeclinedSettlement(false)
        GameManager.SetState(GameConfig.States.DEAD)
        FirstPersonController.SetMouseAbsolute()
        ResultScreen.Show()
        AudioManager.PlayPlayerDeath()
    end)

    -- 广告复活回调：播放本地 Rick Roll 视频，播完后复活
    ResultScreen.OnAdRevive(function()
        -- 显示视频覆盖层，重置并播放
        adVideoPanel_:SetVisible(true)
        adVideoPlayer_:Stop()
        adVideoPlayer_:Seek(0)
        adVideoPlayer_:Play()

        -- 重置跳过按钮状态
        adSkipElapsed_ = 0
        adSkipX_ = math.random(10, 70)
        adSkipY_ = math.random(10, 70)
        adSkipDirX_ = (math.random() > 0.5) and 1 or -1
        adSkipDirY_ = (math.random() > 0.5) and 1 or -1
        adSkipBtn_:SetStyle({ top = math.floor(adSkipY_), left = math.floor(adSkipX_) })
        adSkipBtn_:SetVisible(false)  -- 隐藏跳过按钮，等30秒后显示

        -- 显示倒计时标签
        adCountdownLabel_:SetText(AD_SKIP_DELAY .. "s 后可跳过")
        adCountdownLabel_:SetVisible(true)

        print("[Main] 开始播放广告视频（Rick Roll），场景已暂停")
    end)

    -- 重新开始已由 ResultScreen.OnRestart 处理（见上方）

    -- 14. 订阅事件
    SubscribeToEvent("Update", "HandleUpdate")

    print("=== 游戏已启动 ===")
    print("WASD: 移动 | 鼠标: 视角 | Shift: 冲刺 | F: 交互")
    print("Tab: 图鉴 | M: 地图 | ESC: 暂停 | P: 编辑器")
end

function Stop()
    -- 退出前自动存档
    SaveSystem.Save()
    UI.Shutdown()
end

-- ============================================================================
-- 交互回调设置
-- ============================================================================

function SetupInteractionCallbacks()
    -- 目标变化时更新HUD提示
    InteractionSystem.OnTargetChanged(function(target, targetType)
        if target and targetType then
            local name = nil
            if targetType == "npc" then
                local npcNameVar = target:GetVar("NpcName")
                if npcNameVar and not npcNameVar:IsEmpty() then
                    name = npcNameVar:GetString()
                end
            end
            HUD.ShowInteractHint(targetType, name)
        else
            HUD.HideInteractHint()
        end
    end)

    -- 按F交互时处理
    InteractionSystem.OnInteract(function(target, targetType)
        if targetType == "npc" then
            HandleNPCInteract(target)
        elseif targetType == "item" then
            HandleItemInteract(target)
        elseif targetType == "door" then
            -- 门的开关交互
            VillageBuilder.ToggleDoor(target)
            AudioManager.PlayItemPickup()  -- 复用拾取音效作为开门声
        elseif targetType == "equipment" then
            -- 装备由 AreaBossManager 的 auto-pickup 处理
            -- 手动交互作为备选
            local equipIdVar = target:GetVar("EquipId")
            if equipIdVar and not equipIdVar:IsEmpty() then
                local equipId = equipIdVar:GetString()
                EquipmentSystem.Equip(equipId)
                HUD.ShowEquipNotify(equipId)
                target:Remove()
                local totalHPBonus = LevelSystem.GetMaxHPBonus() + EquipmentSystem.GetMaxHPBonus()
                PlayerHealth.SetMaxHPBonus(totalHPBonus)
            end
        end
    end)
end

-- ============================================================================
-- NPC交互处理
-- ============================================================================

local lastDialogueNpcId_ = nil

---@param node Node
function HandleNPCInteract(node)
    local npcIdVar = node:GetVar("NpcId")
    if not npcIdVar or npcIdVar:IsEmpty() then return end

    local npcId = npcIdVar:GetString()
    lastDialogueNpcId_ = npcId

    -- NPC面向玩家
    NPCManager.FaceTowards(npcId, fpController_:GetPosition())

    -- 隐藏交互提示和准星
    HUD.HideInteractHint()
    HUD.SetCrosshairVisible(false)

    -- 播放对话音效
    AudioManager.PlayDialogueOpen()

    -- 开始对话
    DialogueUI.StartDialogue(npcId)
end

-- ============================================================================
-- 物品拾取处理
-- ============================================================================

---@param node Node
function HandleItemInteract(node)
    local itemIdVar = node:GetVar("ItemId")
    if not itemIdVar or itemIdVar:IsEmpty() then return end

    local itemId = itemIdVar:GetString()

    -- 添加到背包
    GameManager.AddItem(itemId)

    -- 从场景中移除
    ItemSpawner.RemoveItem(itemId)

    -- 播放拾取音效
    AudioManager.PlayItemPickup()

    -- 刷新武器列表（新物品可能解锁武器）
    WeaponSystem.RefreshWeapons()

    -- 显示通知
    HUD.ShowItemNotify(itemId)

    -- 隐藏交互提示
    HUD.HideInteractHint()

    -- 检查任务进度
    CheckQuestProgression()

    -- 自动存档
    SaveSystem.Save()

    print("[Main] 拾取物品: " .. itemId)
end

-- ============================================================================
-- 任务进度检查
-- ============================================================================

function CheckQuestProgression()
    local progress = GameManager.GetQuestProgress()

    if progress == 0 then
        if GameManager.HasItem(GameConfig.Items.FIRE_DRAGON_CARD) then
            GameManager.SetQuestProgress(1)
            print("[Main] 任务进度推进到 1")
        end
    elseif progress == 1 then
        if GameManager.HasItem(GameConfig.Items.BAGUA_MIRROR)
            and GameManager.HasItem(GameConfig.Items.SEALED_SCROLL) then
            GameManager.SetQuestProgress(2)
            print("[Main] 任务进度推进到 2")
        end
    end
end

-- ============================================================================
-- BGM 自动切换（战斗 / 探索）
-- ============================================================================

--- BGM 状态机：Boss BGM 由回调控制，普通战斗/探索在此自动切换
---@param dt number
local function updateBGMState(dt)
    -- Boss BGM 由生成/击败回调控制，此处不干预
    if currentBGMState_ == "dragon" or currentBGMState_ == "ultimate" then
        return
    end

    local hasEnemies = EnemyManager.HasActiveEnemies()
    local bossType = EnemyManager.GetActiveBossType()

    -- 定时Boss存活时也切战斗BGM
    if bossType == "timed" then
        if currentBGMState_ ~= "battle" then
            AudioManager.PlayBattleBGM()
            currentBGMState_ = "battle"
        end
        combatCooldown_ = COMBAT_COOLDOWN
        return
    end

    if hasEnemies then
        combatCooldown_ = COMBAT_COOLDOWN
        if currentBGMState_ ~= "battle" then
            AudioManager.PlayBattleBGM()
            currentBGMState_ = "battle"
        end
    else
        -- 脱战冷却：敌人全灭后等几秒再切回探索
        if currentBGMState_ == "battle" then
            combatCooldown_ = combatCooldown_ - dt
            if combatCooldown_ <= 0 then
                AudioManager.PlayBGM()
                currentBGMState_ = "explore"
            end
        end
    end
end

-- ============================================================================
-- 闪电特效系统
-- ============================================================================

--- 触发闪电特效（多次闪烁白屏）
---@param flashes number 闪烁次数
triggerLightningEffect = function(flashes)
    lightningFlashes_ = flashes
    lightningPhase_ = "flash"
    lightningPhaseDur_ = 0.08  -- 首次闪白持续时间
    if lightningPanel_ then
        lightningPanel_:SetVisible(true)
        lightningPanel_:SetStyle({ backgroundColor = { 255, 255, 255, 200 } })
    end
end

--- 更新闪电特效
---@param dt number
local function updateLightningEffect(dt)
    if lightningPhase_ == "off" then return end

    lightningPhaseDur_ = lightningPhaseDur_ - dt
    if lightningPhaseDur_ > 0 then return end

    if lightningPhase_ == "flash" then
        -- 闪白结束 → 进入暗间隔
        lightningPhase_ = "dark"
        lightningPhaseDur_ = 0.06 + math.random() * 0.1  -- 随机暗间隔
        if lightningPanel_ then
            lightningPanel_:SetStyle({ backgroundColor = { 255, 255, 255, 0 } })
        end
    elseif lightningPhase_ == "dark" then
        lightningFlashes_ = lightningFlashes_ - 1
        if lightningFlashes_ <= 0 then
            -- 全部闪完 → 关闭
            lightningPhase_ = "off"
            if lightningPanel_ then
                lightningPanel_:SetVisible(false)
            end
        else
            -- 继续下一次闪白
            lightningPhase_ = "flash"
            local intensity = 120 + math.random(0, 80)
            lightningPhaseDur_ = 0.05 + math.random() * 0.08
            if lightningPanel_ then
                lightningPanel_:SetStyle({ backgroundColor = { 255, 255, 255, intensity } })
            end
        end
    end
end

-- ============================================================================
-- 帧更新
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    local state = GameManager.GetState()

    -- 移动控件可见性：仅在 PLAYING 状态（非无人机模式）显示
    MobileControls.SetVisible(state == GameConfig.States.PLAYING and not DroneCamera.IsActive())

    if state == GameConfig.States.PLAYING then
        -- L 键切换无人机视角（优先检测，避免被其他逻辑消费）
        if input:GetKeyPress(KEY_L) then
            DroneCamera.Toggle(fpController_)
        end

        if DroneCamera.IsActive() then
            -- 无人机模式：只更新无人机相机 + 世界动画（暂停战斗/玩家逻辑）
            DroneCamera.Update(dt)
            ItemSpawner.Update(dt)
            VillageBuilder.Update(dt)
            -- 无人机模式下，战斗系统也需要出征中才运行
            if SafeZoneSystem.IsOnExpedition() then
                EnemyManager.Update(dt)
                AreaBossManager.Update(dt)
                XPOrbManager.Update(dt, fpController_:GetPosition())
                LootSystem.Update(dt)
            end
        else
            -- 控制桥接：将虚拟控件/手柄输入传递给第一人称控制器
            MobileControls.Update(dt)
            -- 手柄每帧都检测，不依赖模式设置
            GamepadControls.Update(dt)

            -- 自动检测：手柄连接且本帧有输入 → 使用手柄输入
            local useGamepad = GamepadControls.IsConnected() and GamepadControls.IsActive()

            if useGamepad then
                -- 手柄输入：通过玩家实际操作自动判断
                local gx, gz = GamepadControls.GetMoveInput()
                FirstPersonController.SetJoystickInput(gx, gz)
                local dy, dp = GamepadControls.GetLookDelta(dt)
                if dy ~= 0 or dp ~= 0 then
                    FirstPersonController.AddLookDelta(dy, dp)
                end
                FirstPersonController.SetSprint(GamepadControls.IsHeld("sprint"))
                if GamepadControls.WasPressed("jump") then
                    FirstPersonController.SetJump(true)
                end
                if GamepadControls.WasPressed("menu") then
                    GameManager.TogglePause()
                end
                -- 手柄活跃时隐藏虚拟控件
                if MobileControls.IsMobileMode() then
                    MobileControls.SetVisible(false)
                end
            elseif MobileControls.IsMobileMode() then
                -- 触屏摇杆模式
                MobileControls.SetVisible(true)
                local jx, jz = MobileControls.GetJoystickInput()
                FirstPersonController.SetJoystickInput(jx, jz)
                local dy, dp = MobileControls.ConsumeLookDelta()
                if dy ~= 0 or dp ~= 0 then
                    FirstPersonController.AddLookDelta(dy, dp)
                end
                FirstPersonController.SetSprint(MobileControls.IsHeld("sprint"))
                if MobileControls.WasPressed("jump") then
                    FirstPersonController.SetJump(true)
                end
            else
                -- PC 键鼠模式（无虚拟控件、无手柄活跃输入）
                FirstPersonController.SetJoystickInput(0, 0)
                FirstPersonController.SetSprint(false)
            end

            -- 正常游戏：更新控制器、交互、物品动画
            fpController_:Update(dt)
            InteractionSystem.Update(dt)
            ItemSpawner.Update(dt)

            -- 安全区检测始终运行（判断进出安全区）
            SafeZoneSystem.Update(dt, fpController_:GetPosition())

            -- 战斗系统：仅出征中运行
            if SafeZoneSystem.IsOnExpedition() then
                PlayerHealth.Update(dt)
                EnemyManager.Update(dt)
                WeaponSystem.Update(dt)
                SkillSystem.Update(dt)
                LevelSystem.Update(dt)
                XPOrbManager.Update(dt, fpController_:GetPosition())
                AreaBossManager.Update(dt)
                EquipmentSystem.Update(dt)
                KillBonusSystem.Update(dt)
                LootSystem.Update(dt)

                -- 同步装备被动加成（仅在值变化时更新，避免每帧调用）
                local totalHPBonus = LevelSystem.GetMaxHPBonus() + EquipmentSystem.GetMaxHPBonus()
                if totalHPBonus ~= cachedHPBonus_ then
                    cachedHPBonus_ = totalHPBonus
                    PlayerHealth.SetMaxHPBonus(totalHPBonus)
                end
                local speedMult = EquipmentSystem.GetMoveSpeedMult()
                if speedMult ~= cachedSpeedMult_ then
                    cachedSpeedMult_ = speedMult
                    fpController_:SetSpeedMult(speedMult)
                end
            end

            -- 门动画更新
            VillageBuilder.Update(dt)

            -- 脚步声
            AudioManager.UpdateFootsteps(dt, fpController_:IsMoving(), fpController_:IsSprinting())

            -- BGM 自动切换（仅出征中）
            if SafeZoneSystem.IsOnExpedition() then
                updateBGMState(dt)
            end
        end

        -- 天气/氛围系统更新（始终运行，包含过渡动画和粒子）
        WeatherSkySystem.Update(dt, fpController_:GetPosition())

        -- 新手教程更新（教程期间拦截快捷键）
        if TutorialUI.IsActive() then
            TutorialUI.Update(dt)
        end

        -- 检测快捷键（只在 PLAYING 状态下响应，无人机模式下只响应 ESC 退出）
        -- 教程激活期间禁用菜单快捷键（ESC 由教程处理跳过）
        if TutorialUI.IsActive() then
            -- 教程期间不响应任何菜单快捷键
        elseif not DroneCamera.IsActive() then
            if input:GetKeyPress(KEY_P) then
                GameEditor.Toggle()
            elseif input:GetKeyPress(KEY_TAB) then
                AudioManager.PlayMenuOpen()
                CharacterPanelUI.Show()
            elseif input:GetKeyPress(KEY_M) then
                AudioManager.PlayMenuOpen()
                MapUI.Show()
            elseif input:GetKeyPress(KEY_B) then
                AudioManager.PlayMenuOpen()
                HUD.SetCrosshairVisible(false)
                ExchangeShopUI.Show()
            elseif input:GetKeyPress(KEY_ESCAPE) then
                AudioManager.PlayMenuOpen()
                MenuUI.Pause()
            end
        else
            -- 无人机模式下 ESC 退出无人机
            if input:GetKeyPress(KEY_ESCAPE) then
                DroneCamera.Toggle(fpController_)
            end
        end

    elseif state == GameConfig.States.MAIN_MENU then
        -- 开始界面：播放标题呼吸动画
        StartScreen.Update(dt)

    elseif state == GameConfig.States.DEAD then
        -- 广告跳过已移至 updateAdVideo()，在 HandleUpdate 末尾无条件调用

    elseif state == GameConfig.States.LEVEL_UP then
        -- 升级选择状态：经验球继续飞行
        XPOrbManager.Update(dt, fpController_:GetPosition())

    elseif state == GameConfig.States.DIALOGUE then
        DialogueUI.Update(dt)

    elseif state == GameConfig.States.SHOP then
        ShopUI.Update(dt)

    elseif state == GameConfig.States.EXCHANGE_SHOP then
        ExchangeShopUI.Update(dt)

    elseif state == GameConfig.States.CHARACTER_PANEL then
        CharacterPanelUI.Update(dt)

    elseif state == GameConfig.States.MAP then
        MapUI.Update(dt)

    elseif state == GameConfig.States.PAUSED then
        MenuUI.Update(dt)

    elseif state == GameConfig.States.EDITOR then
        GameEditor.Update(dt)
        ItemSpawner.Update(dt)   -- 编辑器中也保持物品浮动动画
    end

    -- HUD 始终更新
    HUD.Update(dt)

    -- 开发者修改摘要面板计时（不受游戏状态影响）
    EditorDevTab.UpdateSummary(dt)

    -- 闪电特效始终更新（不受游戏状态影响）
    updateLightningEffect(dt)

    -- 广告视频跳过按钮始终更新（不受游戏状态影响）
    if adVideoPanel_ and adVideoPanel_:IsVisible() then
        adSkipElapsed_ = adSkipElapsed_ + dt

        if adSkipElapsed_ < AD_SKIP_DELAY then
            -- 倒计时阶段：更新倒计时标签文本，跳过按钮保持隐藏
            local remain = math.ceil(AD_SKIP_DELAY - adSkipElapsed_)
            adCountdownLabel_:SetText(remain .. "s 后可跳过")
            adCountdownLabel_:SetVisible(true)
            adSkipBtn_:SetVisible(false)
        else
            -- 30秒过了：隐藏倒计时标签，显示跳过按钮并开始弹跳移动
            adCountdownLabel_:SetVisible(false)
            adSkipBtn_:SetVisible(true)

            local screenW = graphics:GetWidth() / graphics:GetDPR()
            local screenH = graphics:GetHeight() / graphics:GetDPR()
            local btnW, btnH = 100, 34
            local maxX = screenW - btnW - 10
            local maxY = screenH - btnH - 10

            -- 速度随时间递增：过了30秒后每秒加快
            local elapsed = adSkipElapsed_ - AD_SKIP_DELAY
            local speed = AD_SKIP_BASE_SPEED + AD_SKIP_ACCEL * elapsed

            -- 移动按钮
            adSkipX_ = adSkipX_ + adSkipDirX_ * speed * dt
            adSkipY_ = adSkipY_ + adSkipDirY_ * speed * dt

            -- 碰到边界反弹 + 随机偏转
            if adSkipX_ <= 10 then
                adSkipX_ = 10
                adSkipDirX_ = 1
                adSkipDirY_ = adSkipDirY_ + (math.random() - 0.5) * 0.6
            elseif adSkipX_ >= maxX then
                adSkipX_ = maxX
                adSkipDirX_ = -1
                adSkipDirY_ = adSkipDirY_ + (math.random() - 0.5) * 0.6
            end
            if adSkipY_ <= 10 then
                adSkipY_ = 10
                adSkipDirY_ = 1
                adSkipDirX_ = adSkipDirX_ + (math.random() - 0.5) * 0.6
            elseif adSkipY_ >= maxY then
                adSkipY_ = maxY
                adSkipDirY_ = -1
                adSkipDirX_ = adSkipDirX_ + (math.random() - 0.5) * 0.6
            end

            -- 归一化方向防止累积
            local len = math.sqrt(adSkipDirX_ * adSkipDirX_ + adSkipDirY_ * adSkipDirY_)
            if len > 0.01 then
                adSkipDirX_ = adSkipDirX_ / len
                adSkipDirY_ = adSkipDirY_ / len
            end

            adSkipBtn_:SetStyle({ top = math.floor(adSkipY_), left = math.floor(adSkipX_) })
        end
    end
end
