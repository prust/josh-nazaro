local bump = require "lib.bump"
local cron = require "lib.cron"
local class = require "lib.middleclass"
local vector = require "lib.vector"
local _ = require "lib.moses"

if arg[#arg] == "-debug" then require("mobdebug").start() end

-- constants
MOUSE_BTN_1 = 1
MOUSE_BTN_2 = 2

-- game variables
local is_paused = false
local speed = 256
local pc
local blocks = {}
local enemies = {}
local bullets = {}

-- generic drawable sprite (for prototyping, just a filled rect)
local Sprite = class('Sprite')

function Sprite:draw()
  love.graphics.setColor(self.color)
  love.graphics.rectangle("fill", self.x, self.y, self.width, self.height)
end

local Bullet = class('Bullet', Sprite)
function Bullet:initialize(x, y, dir)
  self.speed = 250
  self.color = {255, 0, 0}
  self.width = 4
  self.height = 4
  self.x = x
  self.y = y
  self.dir = dir
  Sprite.initialize(self)
end

function Bullet:update(dt)
  local should_remove = false
  local dir = self.dir * self.speed * dt
  local x = self.x + dir.x
  local y = self.y + dir.y
  
  local actualX, actualY, cols, len = world:move(self, x, y, function(item, other)
    return "bounce"
  end)

  for i = 1, len do
    local col = cols[i]
    local other = col.other
    if other.type == "player" then
      local did_bounce = false
      if other.shield_dir ~= nil then
        -- TODO: this works for bottom and right, but not top or left
        if other.shield_dir.x == 1 and col.touch.x == other.x + other.width then
          did_bounce = true
        elseif other.shield_dir.y == 1 and col.touch.y == other.y + other.height then
          did_bounce = true
        elseif other.shield_dir.x == -1 and col.touch.x + self.width == other.x then
          did_bounce = true
        elseif other.shield_dir.y == -1 and col.touch.y + self.height == other.y then
          did_bounce = true
        end
      end
      
      if not did_bounce then
        should_remove = true
        other:injure()
        world:remove(self)
      end
    elseif other.type == "wall" then
      should_remove = true
      world:remove(self)
    elseif other.type == "enemy" and self.shooter == "player" then
      should_remove = true
      other:injure()
      world:remove(self)
    end
  end

  if actualX ~= x then
    self.dir.x = -self.dir.x
  end
  if actualY ~= y then
    self.dir.y = -self.dir.y
  end
  
  self.x = actualX
  self.y = actualY
  
  return should_remove
end

-- Playable Character
local Character = class('Character', Sprite)
function Character:initialize()
  self.type = "player"
  self.color = {255, 0, 0}
  self.width = 32
  self.height = 50
  self.x = 0
  self.y = 0
  self.lives = 4
  Sprite.initialize(self)
end

function Character:update(dt)
  local x = self.x
  local y = self.y
  if love.keyboard.isDown("right") or love.keyboard.isDown("d") then
    x = x + (speed * dt)
  elseif love.keyboard.isDown("left") or love.keyboard.isDown("a") then
    x = x - (speed * dt)
  end

  if love.keyboard.isDown("down") or love.keyboard.isDown("s") then
    y = y + (speed * dt)
  elseif love.keyboard.isDown("up") or love.keyboard.isDown("w") then
    y = y - (speed * dt)
  end
  
  local actualX, actualY, cols, len = world:move(self, x, y)
  self.x = actualX
  self.y = actualY
  
  -- shield support
  if love.mouse.isDown(MOUSE_BTN_2) then
    local mouse_x, mouse_y = love.mouse.getPosition()
    dir = vector(mouse_x - self.x, mouse_y - self.y)
    if dir.x == 0 and dir.y == 0 then
      self.shield_dir = nil
    else
      -- normalize the direction in terms of 1,0,-1
      if math.abs(dir.x) > math.abs(dir.y) then
        dir = vector(dir.x > 0 and 1 or -1, 0)
      else
        dir = vector(0, dir.y > 0 and 1 or -1)
      end
      self.shield_dir = dir
    end
  else
    self.shield_dir = nil
  end
end

function Character:draw()
  Sprite.draw(self)
  if self.shield_dir then
    love.graphics.setColor({255, 180, 180})
    if self.shield_dir.x ~= 0 then
      local x = self.shield_dir.x > 0 and self.x + self.width or self.x
      love.graphics.rectangle("fill", x, self.y, 2, self.height)
    else
      local y = self.shield_dir.y > 0 and self.y + self.height or self.y
      love.graphics.rectangle("fill", self.x, y, self.width, 2)
    end
  end
end

function Character:shoot()
  local x, y = love.mouse.getPosition()
  shoot(self, x, y)
end

function Character:injure()
  self.lives = self.lives - 1
  if self.lives == 0 then
    is_paused = true
  end
end

-- enemy
local Enemy = class('Enemy', Sprite)
function Enemy:initialize(x, y)
  self.type = "enemy"
  self.color = {0, 0, 255}
  self.width = 32
  self.height = 32
  self.x = x
  self.y = y
  self.dir = vector(0, 0)
  self.clock = nil
  self.shot_clock = nil
  Sprite.initialize(self)
end

function Enemy:update(dt)
  if self.clock then
    self.clock:update(dt)
  end
  if self.shot_clock then
    self.shot_clock:update(dt)
  end
  
  local dir = self.dir * speed * dt
  local x = self.x + dir.x
  local y = self.y + dir.y
  
  local actualX, actualY, cols, len = world:move(self, x, y)
  self.x = actualX
  self.y = actualY
end

function Enemy:injure()
  world:remove(self)
  local ix
  for i = 1, #enemies do
    if enemies[i] == self then
      ix = i
    end
  end
  
  table.remove(enemies, ix)
end

function Enemy:shoot()
  -- TODO: target Josh Nazaro, not the playable character
  shoot(self, pc.x, pc.y)
  self.shot_clock = cron.after(math.random(3), self.shoot, self)
end

function Enemy:changeDirection()
  -- move parallel to target
  -- TODO: back away if good guys are too close, run away if they're closing in
  -- TODO: target Josh Nazaro, not the playable character
  local dir = vector(pc.x - self.x, pc.y - self.y)
  dir:normalizeInplace()
  dir = dir:perpendicular()
  
  -- there are 2 perpendicular angles, randomize which one is chosen
  if math.random(2) == 1 then
    dir = -dir
  end
  
  self.dir = dir
  self.clock = cron.after(math.random(2), self.changeDirection, self)
end

-- movable block
local Block = class('Block', Sprite)
function Block:initialize(x, y)
  self.color = {40, 40, 40}
  self.width = 32
  self.height = 32
  self.x = x
  self.y = y
  Sprite.initialize(self)
end

-- helper functions
function shoot(shooter, target_x, target_y)
  local dir = vector(target_x - shooter.x, target_y - shooter.y)
  dir:normalizeInplace()
  
  -- avoid collisions with the sprite shooting the bullet
  -- by spawning it on the correct side of the character
  local bullet_width = 4
  local x = dir.x > 0 and shooter.x + shooter.width + 1 or shooter.x - 1 - bullet_width
  
  -- shoot bullets from the "waist" of the character
  local y = shooter.y + shooter.height / 2
  
  local bullet = Bullet:new(x, y, dir)
  bullet.shooter = shooter.type
  addSprite(bullet)
  table.insert(bullets, bullet)
end

function addSprite(spr)
  world:add(spr, spr.x, spr.y, spr.width, spr.height)
end

function generateBlocks()
  local win_width = love.graphics.getWidth()
  local win_height = love.graphics.getHeight()
  local num_blocks_x = win_width / 32
  local num_blocks_y = win_height / 32
  
  local block
  local block_ix = 1
  for y = 1, num_blocks_y do
    for x = 1, num_blocks_x do
      -- avoid creating blocks at 1,1 or 1,2, so they don't overlap w/ the pc
      if x > 1 or y > 2 then
        if math.random(15) == 1 then
          if math.random(10) == 1 then
            enemy = Enemy:new((x - 1) * 32, (y - 1) * 32)
            table.insert(enemies, enemy)
            addSprite(enemy)
          else
            block = Block:new((x - 1) * 32, (y - 1) * 32)
            table.insert(blocks, block)
            addSprite(block)
          end
        end
      end
    end
  end
  
  for i = 1, #enemies do
    enemies[i]:shoot()
    enemies[i]:changeDirection()
  end
end

-- game callbacks
function love.load(arg)
  -- nearest neightbor & full-screen
  love.graphics.setDefaultFilter( 'nearest', 'nearest' )
  --love.window.setFullscreen(true)
  
  -- prepare simple AABB collision world w/ cell size
  world = bump.newWorld(64)
  pc = Character:new()
  addSprite(pc)
  
  generateBlocks()
  
  -- add 4 walls around the visible screen to prevent players/enemies from going offscreen
  local win_width = love.graphics.getWidth()
  local win_height = love.graphics.getHeight()
  addSprite({type="wall", x=-1, y=-1, height=1, width = win_width + 2})
  addSprite({type="wall", x=-1,y=-1, height = win_height + 2, width = 1})
  addSprite({type="wall", x=win_width+1, y=-1, height = win_height + 2, width = 1})
  addSprite({type="wall", x=-1, y = win_height+1, height = 1, width = win_width + 2})
end

function love.update(dt)
  if is_paused then return end
  pc:update(dt)
  for i = 1, #enemies do
    enemies[i]:update(dt)
  end
  
  local bullets_to_remove = {}
  for i = 1, #bullets do
    local should_remove = bullets[i]:update(dt)
    if should_remove then
      table.insert(bullets_to_remove, i)
    end
  end
  
  -- remove removed bullets in reverse order to not mess up iteration
  for i = #bullets_to_remove, 1, -1 do
    table.remove(bullets, bullets_to_remove[i])
  end

  -- only compact if there is a need, for performance reasons
  if _.any(bullets, function(val) return not val end) then
    bullets = _.compact(bullets)
  end
end

function love.draw()  
  pc:draw()
  
  for i = 1, #blocks do
    blocks[i]:draw()
  end
  
  for i = 1, #enemies do
    enemies[i]:draw()
  end
  
  for i = 1, #bullets do
    bullets[i]:draw()
  end
  
  if is_paused then
    love.graphics.setColor(255, 255, 255)
    local win_width = love.graphics.getWidth()
    local win_height = love.graphics.getHeight()
    love.graphics.print("Game Over", win_width / 2 - 50, win_height / 2 - 30, 0, 2, 2)
  end
end

function love.keypressed(k)
   if k == 'escape' then
      love.event.quit()
   end
end

function love.mousereleased(x, y, button, istouch)
  if button == MOUSE_BTN_1 and not love.mouse.isDown(MOUSE_BTN_2) then
    pc:shoot()
  end
end
