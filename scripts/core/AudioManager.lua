-- ============================================================================
-- AudioManager.lua — 音频管理器
-- 管理背景音乐（多轨切换）和音效播放
-- ============================================================================

local AudioManager = {}

---@type Node
local musicNode_ = nil
---@type SoundSource
local musicSource_ = nil
---@type Scene
local scene_ = nil

-- 当前播放的 BGM 标识
local currentBGM_ = ""

-- 音效资源路径
local SFX = {
    ITEM_PICKUP      = "audio/sfx/item_pickup.ogg",
    DIALOGUE_OPEN    = "audio/sfx/dialogue_open.ogg",
    DIALOGUE_ADVANCE = "audio/sfx/dialogue_advance.ogg",
    MENU_OPEN        = "audio/sfx/menu_open.ogg",
    FOOTSTEP_GRASS   = "audio/sfx/footstep_grass.ogg",
    -- 战斗音效
    SWORD_SWING_1    = "audio/sfx/sword_swing_1.ogg",
    SWORD_SWING_2    = "audio/sfx/sword_swing_2.ogg",
    SWORD_SWING_3    = "audio/sfx/sword_swing_3.ogg",
    HIT_PUNCH        = "audio/sfx/hit_punch.ogg",
    HIT_WEAPON       = "audio/sfx/hit_weapon.ogg",
    PLAYER_HURT      = "audio/sfx/player_hurt.ogg",
    PLAYER_DEATH     = "audio/sfx/player_death.ogg",
    ENEMY_DEATH      = "audio/sfx/enemy_death.ogg",
    EXPLOSION        = "audio/sfx/explosion.ogg",
    TRAP_TRIGGER     = "audio/sfx/trap_trigger.ogg",
    -- 升级 / 经验
    LEVEL_UP         = "audio/sfx/level_up.ogg",
    XP_COLLECT       = "audio/sfx/xp_collect.ogg",
    -- 技能音效
    SKILL_FIREBALL   = "audio/sfx/skill_fireball.ogg",
    SKILL_SHIELD     = "audio/sfx/skill_shield.ogg",
    SKILL_LIGHTNING   = "audio/sfx/skill_lightning.ogg",
    SKILL_WHIRLWIND  = "audio/sfx/skill_whirlwind.ogg",
    SKILL_FREEZE     = "audio/sfx/skill_freeze.ogg",
    SKILL_TRAP       = "audio/sfx/skill_trap.ogg",
    SKILL_PURIFY     = "audio/sfx/skill_purify.ogg",
    SKILL_HOMING     = "audio/sfx/skill_homing.ogg",
    SKILL_PIERCE     = "audio/sfx/skill_pierce.ogg",
    SKILL_BEAM       = "audio/sfx/skill_beam.ogg",
    -- Boss 特殊音效
    BOSS_ENTRANCE    = "audio/sfx/boss_entrance.ogg",
    THUNDER_STRIKE   = "audio/sfx/thunder_strike.ogg",
}

-- BGM 路径表
local BGM = {
    EXPLORE  = "audio/music_1776953839715.ogg",       -- 探索/日常
    BATTLE   = "audio/music_1776984038661.ogg",       -- 战斗
    DRAGON   = "audio/music_1776984127628.ogg",       -- 挑战Boss（龙）
    ULTIMATE = "audio/music_1776984196668.ogg",       -- 最终Boss
}

-- 脚步声控制
local footstepTimer_ = 0
local footstepInterval_ = 0.45  -- 脚步声间隔(秒)

-- ============================================================================
-- 初始化
-- ============================================================================

---@param scene Scene
function AudioManager.Init(scene)
    scene_ = scene

    -- 添加 SoundListener 到场景
    local listenerNode = scene:CreateChild("SoundListener")
    local listener = listenerNode:CreateComponent("SoundListener")
    audio:SetListener(listener)

    -- 创建BGM节点
    musicNode_ = scene:CreateChild("BGMNode")
    musicSource_ = musicNode_:CreateComponent("SoundSource")
    musicSource_:SetSoundType("Music")

    -- 设置主音量
    audio:SetMasterGain("Music", 0.4)
    audio:SetMasterGain("Effect", 0.7)

    currentBGM_ = ""

    print("[AudioManager] 初始化完成")
end

-- ============================================================================
-- BGM 切换系统
-- ============================================================================

--- 内部：播放指定 BGM（若已在播放则跳过）
---@param bgmKey string BGM 标识（BGM 表的 key）
---@param forceRestart? boolean 是否强制重头播放
local function switchBGM(bgmKey, forceRestart)
    if not musicSource_ then return end
    if currentBGM_ == bgmKey and not forceRestart then return end

    local path = BGM[bgmKey]
    if not path then
        print("[AudioManager] 未知 BGM: " .. tostring(bgmKey))
        return
    end

    local sound = cache:GetResource("Sound", path)
    if sound then
        sound.looped = true
        musicSource_:Play(sound)
        currentBGM_ = bgmKey
        print("[AudioManager] BGM 切换 → " .. bgmKey)
    else
        print("[AudioManager] BGM 资源未找到: " .. path)
    end
end

--- 播放探索/日常 BGM
function AudioManager.PlayBGM()
    switchBGM("EXPLORE")
end

--- 播放战斗 BGM
function AudioManager.PlayBattleBGM()
    switchBGM("BATTLE")
end

--- 播放挑战Boss BGM（龙Boss）
function AudioManager.PlayDragonBGM()
    switchBGM("DRAGON")
end

--- 播放最终Boss BGM（深渊魔王）
function AudioManager.PlayUltimateBGM()
    switchBGM("ULTIMATE")
end

--- 获取当前 BGM 标识
---@return string
function AudioManager.GetCurrentBGM()
    return currentBGM_
end

function AudioManager.StopBGM()
    if musicSource_ then
        musicSource_:Stop()
        currentBGM_ = ""
    end
end

---@param gain number 0.0~1.0
function AudioManager.SetMusicVolume(gain)
    audio:SetMasterGain("Music", gain)
end

-- ============================================================================
-- 音效播放
-- ============================================================================

---@param sfxPath string 音效资源路径
---@param gain? number 音量 (默认1.0)
local function playSFX(sfxPath, gain)
    if not scene_ then return end

    local sound = cache:GetResource("Sound", sfxPath)
    if not sound then
        print("[AudioManager] 音效未找到: " .. sfxPath)
        return
    end

    local node = scene_:CreateChild("SFX")
    local source = node:CreateComponent("SoundSource")
    source:SetSoundType("Effect")
    source.gain = gain or 1.0
    source.autoRemoveMode = REMOVE_NODE
    source:Play(sound)
end

function AudioManager.PlayItemPickup()
    playSFX(SFX.ITEM_PICKUP, 0.8)
end

function AudioManager.PlayDialogueOpen()
    playSFX(SFX.DIALOGUE_OPEN, 0.5)
end

function AudioManager.PlayDialogueAdvance()
    playSFX(SFX.DIALOGUE_ADVANCE, 0.4)
end

function AudioManager.PlayMenuOpen()
    playSFX(SFX.MENU_OPEN, 0.6)
end

function AudioManager.PlayFootstep()
    playSFX(SFX.FOOTSTEP_GRASS, 0.3)
end

-- ============================================================================
-- 战斗音效
-- ============================================================================

local swingSfx_ = { SFX.SWORD_SWING_1, SFX.SWORD_SWING_2, SFX.SWORD_SWING_3 }
local swingIdx_ = 0

--- 挥剑空挥音效（3 种随机轮换）
function AudioManager.PlaySwordSwing()
    swingIdx_ = swingIdx_ % #swingSfx_ + 1
    playSFX(swingSfx_[swingIdx_], 0.55)
end

function AudioManager.PlayHitPunch()
    playSFX(SFX.HIT_PUNCH, 0.7)
end

function AudioManager.PlayHitWeapon()
    playSFX(SFX.HIT_WEAPON, 0.7)
end

function AudioManager.PlayPlayerHurt()
    playSFX(SFX.PLAYER_HURT, 0.8)
end

function AudioManager.PlayPlayerDeath()
    playSFX(SFX.PLAYER_DEATH, 0.9)
end

function AudioManager.PlayEnemyDeath()
    playSFX(SFX.ENEMY_DEATH, 0.6)
end

function AudioManager.PlayExplosion()
    playSFX(SFX.EXPLOSION, 0.75)
end

function AudioManager.PlayTrapTrigger()
    playSFX(SFX.TRAP_TRIGGER, 0.75)
end

-- ============================================================================
-- Boss 特殊音效
-- ============================================================================

--- Boss 登场咆哮（终极Boss用）
function AudioManager.PlayBossEntrance()
    playSFX(SFX.BOSS_ENTRANCE, 1.0)
end

--- 雷鸣音效（挑战Boss用）
function AudioManager.PlayThunderStrike()
    playSFX(SFX.THUNDER_STRIKE, 1.0)
end

-- ============================================================================
-- 升级 / 经验音效
-- ============================================================================

function AudioManager.PlayLevelUp()
    playSFX(SFX.LEVEL_UP, 0.9)
end

function AudioManager.PlayXPCollect()
    playSFX(SFX.XP_COLLECT, 0.35)
end

-- ============================================================================
-- 技能音效
-- ============================================================================

---@param weaponId string|nil nil=徒手
function AudioManager.PlaySkillSFX(weaponId)
    if not weaponId then
        playSFX(SFX.HIT_PUNCH, 0.7)
        return
    end
    local map = {
        fire_dragon_card   = SFX.SKILL_FIREBALL,
        peace_jade         = SFX.SKILL_SHIELD,
        secret_key         = SFX.SKILL_PIERCE,
        bagua_mirror       = SFX.SKILL_BEAM,
        exorcism_talisman  = SFX.SKILL_HOMING,
        mystery_fragment   = SFX.SKILL_LIGHTNING,
        opened_scroll      = SFX.SKILL_WHIRLWIND,
        sealed_scroll      = SFX.SKILL_FREEZE,
        secret_box         = SFX.SKILL_TRAP,
        holy_water         = SFX.SKILL_PURIFY,
    }
    local sfx = map[weaponId]
    if sfx then
        playSFX(sfx, 0.75)
    end
end

-- ============================================================================
-- 脚步声更新
-- ============================================================================

---@param dt number
---@param isMoving boolean
---@param isSprinting boolean
function AudioManager.UpdateFootsteps(dt, isMoving, isSprinting)
    if not isMoving then
        footstepTimer_ = 0
        return
    end

    local interval = isSprinting and (footstepInterval_ * 0.65) or footstepInterval_
    footstepTimer_ = footstepTimer_ + dt

    if footstepTimer_ >= interval then
        footstepTimer_ = footstepTimer_ - interval
        AudioManager.PlayFootstep()
    end
end

return AudioManager
