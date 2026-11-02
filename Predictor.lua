--!nocheck
-- BallTrajectoryPredictor.lua | injection-ready | 2026-11-02
-- Самодостаточный локальный скрипт для экзекьютора (LocalScript-контекст).

if not game:IsLoaded() then game.Loaded:Wait() end

task.spawn(function()

--[[
	BallTrajectoryPredictor.client.lua (v2, финал)
	Куда: StarterPlayer > StarterPlayerScripts

	Предсказывает траекторию мяча на корте.
	Заточен под плейс "UPD Neo Tennis": физический мяч Workspace.CourtTraining1.Ball
	синхронизируется сервером, а КЛИЕНТСКАЯ копия Ball.ClientBall живёт на локальной
	физике (VectorForce Buoyancy + Special + SyncRE задаёт скорость). Поэтому предсказание
	строим по ClientBall: читаем его актуальные силы и скорость и интегрируем вперёд —
	учитывается та же физика, что и у самого мяча (включая BuoyancyForce игры).

	Что делает:
	- Каждый кадр рисует прогнозную траекторию точками + маркер точки падения.
	- HUD с ускорением, скоростью, временем до земли и координатами падения.
	- Точечный raycast корта для точки падения.

	Hotkeys: P — показать/скрыть прогноз.
	Hooks:   _G.BallPredictToggle(on / nil=switch), _G.BallPredictState()
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local player = Players.LocalPlayer

--==========================================================================
-- Конфиг
--==========================================================================
local CONFIG = {
	HORIZON      = 2.5,   -- сек прогноза
	DT           = 0.05,  -- шаг интегрирования (полу-Эйлер)
	POINT_EVERY  = 4,     -- точка визуала каждые N шагов (0.2 c)
	MAX_POINTS   = 50,
	LANDING_TAG  = "Landing", -- маркер
	DOT_COLOR    = Color3.fromRGB(255, 190, 60),
	LAND_COLOR   = Color3.fromRGB(255, 70, 70),
	ENABLED      = true,
}

-- Кандидаты на физический мяч (директории первой очереди)
local function resolveBall()
	-- 1) прямые пути, известные по этому плейсу
	local courts = Workspace:FindFirstChild("CourtTraining1")
	local ball = courts and courts:FindFirstChild("Ball")
	if ball and ball:FindFirstChild("ClientBall") then return ball, ball.ClientBall end
	-- 2) общий поиск: BasePart "Ball" c ребёнком ClientBall/RemoteEvent SyncRE
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("BasePart") and inst.Name == "Ball" then
			local cb = inst:FindFirstChild("ClientBall")
			if cb then return inst, cb end
		elseif inst:IsA("BasePart") and inst:GetAttribute("IsBall") == true then
			return inst, inst
		end
	end
	return nil, nil
end

--==========================================================================
-- Визуал прогноза
--==========================================================================
local dotsFolder = Instance.new("Folder")
dotsFolder.Name = "BallTrajectoryDots"
dotsFolder.Parent = Workspace

local landing = Instance.new("Part")
landing.Name = "BallLandingMarker"
landing.Anchored = true
landing.CanCollide = false
landing.CanQuery = false
landing.CanTouch = false
landing.Shape = Enum.PartType.Cylinder
landing.Size = Vector3.new(0.15, 2.4, 2.4)
landing.Material = Enum.Material.Neon
landing.Color = CONFIG.LAND_COLOR
landing.Transparency = 0.3
landing.Parent = dotsFolder

local dots = table.create(CONFIG.MAX_POINTS)
for i = 1, CONFIG.MAX_POINTS do
	local dot = Instance.new("Part")
	dot.Name = "Dot"
	dot.Anchored = true
	dot.CanCollide = false
	dot.CanQuery = false
	dot.CanTouch = false
	dot.Shape = Enum.PartType.Ball
	dot.Material = Enum.Material.Neon
	dot.Color = CONFIG.DOT_COLOR
	dot.Size = Vector3.one * 0.35
	dot.Transparency = 1
	dot.Parent = dotsFolder
	dots[i] = dot
end

-- HUD
local gui = Instance.new("ScreenGui")
gui.Name = "BallPredictGUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.Parent = player:WaitForChild("PlayerGui")

local hud = Instance.new("Frame")
hud.Size = UDim2.new(0, 250, 0, 96)
hud.Position = UDim2.new(0, 12, 0, 12)
hud.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
hud.BackgroundTransparency = 0.3
hud.BorderSizePixel = 0
hud.Parent = gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = hud

local text = Instance.new("TextLabel")
text.Size = UDim2.new(1, -16, 1, -12)
text.Position = UDim2.new(0, 8, 0, 6)
text.BackgroundTransparency = 1
text.Font = Enum.Font.Code
text.TextSize = 13
text.TextXAlignment = Enum.TextXAlignment.Left
text.TextYAlignment = Enum.TextYAlignment.Top
text.TextColor3 = Color3.fromRGB(255, 220, 130)
text.Parent = hud

--==========================================================================
-- Физика прогноза
--==========================================================================

-- Ускорение машины "клиентский мяч": VectorForce-и внутри ClientBall + гравитация.
-- VectorForce.RelativeTo может быть World/Attachment0/Attachment1 — корректно преобразуем.
local function worldForce(force, clientBall)
	local f = force.Force
	local rel = force.RelativeTo
	if rel == Enum.ActuatorRelativeTo.World then
		return f
	elseif (rel == Enum.ActuatorRelativeTo.Attachment0 or rel == Enum.ActuatorRelativeTo.Attachment1) then
		local att = rel == Enum.ActuatorRelativeTo.Attachment0 and force.Attachment0 or force.Attachment1
		if att and att.Parent and att.Parent:IsA("BasePart") then
			return att.Parent.CFrame:VectorToWorldSpace(f)
		end
	end
	return f -- Vecto / unknown: считаем мировым (при World всё равно так)
end

-- Возвращает (points, landingPos, hitT) или nil если мяч не летит/не найден
local function simulate(clientBall, meshRadius)
	local mass = clientBall.AssemblyMass
	if mass <= 0 then return nil end

	local pos = clientBall.Position
	local vel = clientBall.AssemblyLinearVelocity
	local acc = Vector3.new(Workspace.GlobalWind.X, -Workspace.Gravity, Workspace.GlobalWind.Z)
	local buoy = clientBall:FindFirstChild("BuoyancyForce")
	local spec = clientBall:FindFirstChild("SpecialForce")
	local windForce = Vector3.zero
	if buoy and buoy:IsA("VectorForce") then windForce += worldForce(buoy, clientBall) end
	if spec and spec:IsA("VectorForce") then windForce += worldForce(spec, clientBall) end
	acc += windForce / mass

	-- Если мяч стоит на месте / зажат в руке — прогноз не рисуем
	if vel.Magnitude < 2 then return nil end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { dotsFolder, clientBall.Parent, clientBall }
	rayParams.IgnoreWater = true

	local points = {}
	local n = 0
	local t = 0
	local steps = math.floor(CONFIG.HORIZON / CONFIG.DT)
	local ballCF = clientBall.CFrame

	for i = 1, steps do
		t += CONFIG.DT
		-- полу-Эйлер; силы берём актуальные на этот кадр (синк может их поменять)
		vel += acc * CONFIG.DT
		local step = vel * CONFIG.DT
		local ray = Workspace:Raycast(pos, step, rayParams)
		if ray then
			-- столкнулись: прогнозная точка — на месте удара
			n += 1
			points[n] = ray.Position
			return points, ray.Position, t
		end
		pos += step
		if i % CONFIG.POINT_EVERY == 0 then
			n += 1
			points[n] = pos
			if n >= CONFIG.MAX_POINTS then break end
		end
		if pos.Y < -200 then break end
	end
	return points, pos, math.min(t, CONFIG.HORIZON)
end

--==========================================================================
-- Цикл рендера
--==========================================================================
local enabled = CONFIG.ENABLED
local smoothPts = {}

local function setDotsVisible(count)
	for i, d in ipairs(dots) do
		if i <= count then
			d.Transparency = 0.2 + 0.55 * (i / #dots) -- плавное угасание
			d.Size = Vector3.one * math.max(0.18, 0.42 - 0.15 * (i / #dots))
		else
			d.Transparency = 1
		end
	end
end

local function clearDots()
	for _, d in ipairs(dots) do d.Transparency = 1 end
	landing.Transparency = 1
end

RunService.RenderStepped:Connect(function()
	if not enabled then
		clearDots()
		hud.Visible = false
		return
	end
	hud.Visible = true

	local ball, clientBall = resolveBall()
	if not clientBall then
		text.Text = "Мяч не найден\n(стенды: CourtTraining1.Ball)"
		clearDots()
		return
	end

	local points, landingPos, tLeft = simulate(clientBall)
	if not points then
		text.Text = "Мяч найден, но стоит на месте\nпрогноз не рисуется"
		clearDots()
		return
	end

	-- Лёгкое сглаживание, чтобы точки не дрожали от частых синков
	for i, pt in ipairs(points) do
		local prev = smoothPts[i]
		smoothPts[i] = prev and prev:Lerp(pt, 0.45) or pt
	end
	setDotsVisible(#points)

	landing.Position = smoothPts[#smoothPts]
	landing.CFrame = CFrame.new(landing.Position) * CFrame.Angles(0, 0, math.rad(90))
	landing.Transparency = 0.3

	local vel = clientBall.AssemblyLinearVelocity
	local speed = vel.Magnitude
	text.Text = ("Мяч: %s\nСкорость: %.1f ст/с\nПолёт ~ %.2f c\nПадение: (%.0f, %.0f, %.0f)\nНажми P чтобы скрыть"):format(
		clientBall.Parent.Name, speed, tLeft, landing.Position.X, landing.Position.Y, landing.Position.Z
	)
end)

--==========================================================================
-- Хоткей и хуки
--==========================================================================
UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == Enum.KeyCode.P then
		enabled = not enabled
	end
end)

_G.BallPredictToggle = function(on: )
	enabled = (on == nil) and (not enabled) or on
	return enabled
end
_G.BallPredictState = function()
	return { enabled = enabled }
end

setDotsVisible(0)
print("[BallTrajectoryPredictor] загружен. P — вкл/выкл прогноз.")

end)
