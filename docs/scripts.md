# Справочник по скриптам

Для каждого скрипта: зачем он нужен, главное API и кто им пользуется. Алгоритм генерации целиком описан в [dungeon_generation.md](dungeon_generation.md), единицы измерения — в [conventions.md](conventions.md).

**Обозначения:**
- **(статический)** — класс без состояния, только `static func`.
- **(ресурс)** — `Resource`, данные лежат в `.tres` и правятся в редакторе.
- **Внутренние** функции начинаются с `_` и здесь не перечисляются.

```
src/
├── core/world_units.gd                    единицы измерения
├── combat/                                чистая логика боя
├── dungeon/
│   ├── dungeon_types.gd                   общие перечисления
│   ├── dungeon_config.gd, biome_data.gd,
│   │   prop_def.gd, prop_rule.gd          данные-ресурсы
│   ├── dungeon_data.gd, room_data.gd,
│   │   room_map.gd                        результат генерации
│   ├── generation/                        генерация
│   ├── physics/                           коллизии
│   ├── render/                            2D-отрисовка
│   └── import/                            импорт биома из листов тайлов
├── heroes/                                отряд героев (фиксированные такты)
├── net/                                   сетевой транспорт без игровых правил
└── enemies/                               ИИ врагов
    ├── enemy_definition.gd                параметры врага (ресурс)
    ├── room_navigation.gd                 навмеш комнаты
    └── basic_enemy.gd                     базовый ближний враг
scenes/debug/                              просмотрщик и отладка
tests/                                     автотесты
tools/import_biome.gd                      импорт биома (CLI)
tools/recolor_hills.py                     перекраска обрывов под палитру
```

---

## Ядро

### `src/core/actor_id_allocator.gd` — `ActorIdAllocator`

Монотонные положительные ID в пределах забега. **`allocate()`** выдаёт следующий ID, **`allocate_block(count)`** — непрерывный `Array[int]` для отряда. ID не переиспользуются после смены комнаты. Владелец забега передаёт их героям и врагам до регистрации в `DamageSystem`.

### `src/core/world_units.gd` — `WorldUnits` (статический)

Единая система измерения длины в проекте: 1 метр = 1 клетка сетки, игра чисто 2D. Пиксели получаются только отсюда.

- **Константы:**
  - `CELL_SIZE` — метров в клетке (1);
  - `PIXELS_PER_METER` — пикселей в метре (16);
  - `CELL_PIXELS` — пикселей в клетке.
- **`cell_to_world(cell) -> Vector2`** — центр клетки в метрах. Сетка x → мир x, сетка y → мир y. Уровень рельефа — не ось мира, а номер уровня клетки.
- **`world_to_cell(position) -> Vector2i`** — клетка под точкой мира.
- **`cell_to_pixels(cell)`, `meters_to_pixels(m)`, `pixels_to_meters(px)`** — переводы в пиксели и обратно.

**Кто использует:** рендер, коллизии, просмотрщик, отладочный слой, тестовый герой.

---

## Сеть (`src/net/`)

### `network_transport.gd` — `NetworkTransport`

Базовая граница байтовых пакетов между сессией и backend. Сигналы `peer_connected(peer_id)`, `peer_disconnected(peer_id)`, `packet_received(sender_id, packet)`; API `poll()`, `send_to(peer_id, packet, reliable)`, `close()`, `is_open()`. Не знает игровые сообщения и правила боя. Внешние callbacks должны доходить до сессии только через явный `poll()`.

### `loopback_transport.gd` — `LoopbackTransport`

Детерминированная пара локальных endpoint'ов для тестов и будущих локальных сессий. **`create_pair()`** возвращает `[host, client]` с ID 0 и 1. `send_to()` копирует `PackedByteArray` в очередь другого endpoint; доставка происходит при его `poll()`. Неизвестный peer и отправка после `close()` возвращают `false`. `close()` ставит disconnect-события обеим сторонам и разрывает циклические ссылки пары.

### `handshake_codec.gd` — `HandshakeCodec` (статический)

Явный little-endian кодек handshake без десериализации `Variant`/объектов. Заголовок: magic `WRPG` как `u32`, затем `kind: u8`. `CLIENT_HELLO`: `protocol_version: u16`, `build_version` и `content_hash` как UTF-8 с длиной `u16`. `HOST_WELCOME`: protocol version, `session_id: u32`, `player_slot: u8` (0–3). `REJECT`: строка причины. **`encode(Message)`** возвращает пустой буфер для невалидного сообщения; **`decode(packet)`** возвращает `null` при неизвестном типе, нарушении границ, лишних байтах и невалидных полях. Лимиты: пакет 1024 байта, строка 128 байт.

### `host_session.gd` — `HostSession`

Handshake-владелец хоста. `setup(transport)` подключает сигналы, `poll()` явно продвигает транспорт, `slot_for(peer_id)` возвращает назначенный слот или −1. Точно сверяет protocol/build/content, выдаёт слоты 1–3, отвечает `HOST_WELCOME` или `REJECT`. Повторный hello получает тот же слот без повторного `client_accepted`. Сигналы `client_accepted`, `client_rejected`, `client_disconnected`. `dispose()` отключает сигналы; транспортом не владеет и не закрывает его.

### `client_session.gd` — `ClientSession`

Клиент handshake с состояниями `IDLE`, `CONNECTING`, `ACCEPTED`, `REJECTED`, `DISCONNECTED`. `start()` один раз отправляет hello хосту (peer 0); `accepted(session_id, player_slot)` и `rejected(reason)` сообщают результат. После принятия игнорирует handshake-дубли. `dispose()` отключает сигналы без закрытия внешнего транспорта.

---

## Бой (`src/combat/`)

Архитектура и причины — в [damage_modifiers.md](damage_modifiers.md). Всё боевое ядро — `RefCounted`/`Resource` без узлов сцены; симуляция идёт фиксированными тактами (по умолчанию 60/с).

### `combat_types.gd` — `CombatTypes` (статический)

Общие перечисления боя.

- **`DamageType`** — `PHYSICAL`, `MAGICAL` (индекс массивов статов).
- **`Faction`** — `HERO`, `ENEMY`.
- **`Stat`** — что меняет `ModifierOperation`: `FLAT_DAMAGE`, `OUTGOING_ADDITIVE`, `OUTGOING_MULTIPLIER`, `INCOMING_ADDITIVE`, `DEFENSE`, `MAX_HP`, `MAX_POISE`.
- **`Status`** — `NONE`, `BURN`, `POISON`, `CHILL`, `FREEZE`, `STUN`, `BLEED`.
- **`AttackTag`** — флаги `NONE=0`, `MELEE=1`, `PROJECTILE=2`, `AOE=4`, `DOT=8`.

### `damage_calculator.gd` — `DamageCalculator` (статический)

Чистый числовой расчёт урона без зависимости от узлов, времени, FPS, RNG и отображения. Не изменяет здоровье или другое состояние существ.

- **`resolve_into(request, result)`** — заполняет существующий `DamageResult`, не создавая результат на каждый расчёт.
- Порядок: база плюс плоский бонус → аддитивный исходящий бонус → особый множитель → входящий бонус цели → `mitigation`.
- Отрицательный итог каждой стадии ограничивается нулём. `mitigation` ограничен диапазоном 0–2.

### `defense_formula.gd` — `DefenseFormula` (статический)

Переводит защиту со знаком в множитель урона в стиле Dota: `mitigation = 1 − (c·d) / (1 + |c·d|)`.

- **`mitigation(defense, constant = 0.06) -> float`** — диапазон результата 0–2 (иммунитет — максимальная уязвимость ×2), без нуля в знаменателе. Вызывается из `CombatStats` при пересборке.

### `damage_request.gd` — `DamageRequest`

Числовой вход одного расчёта: `damage_type`, `base_damage`, `flat_bonus`, `outgoing_additive`, `outgoing_multiplier`, `incoming_additive`, `mitigation`, `poise_damage`. Переиспользуется; модификаторы агрегирует вызывающая сторона (`DamageSystem`).

### `damage_result.gd` — `DamageResult`

Переиспользуемый выход расчёта: `damage`, `poise_damage`, `actual_damage` (что реально снялось с HP), `prevented`, `target_died`, `staggered`. Применение к здоровью — отдельная операция (`CombatantState.apply_result`).

### `combatant_definition.gd` — `CombatantDefinition` (ресурс)

Базовые данные бойца (метры и секунды): `display_name`, `speed`, `radius`, `max_hp` (10), `max_poise` (100), `physical_defense`, `magical_defense`, `poise_regen_delay` (0,8 с), `poise_regen_per_second` (50). Наследуются `HeroDefinition` и `EnemyDefinition`.

### `combatant_state.gd` — `CombatantState`

Runtime-состояние бойца, независимое от визуального узла: `actor_id`, `faction`, `definition`, `modifiers` (`ModifierSet`), `statuses` (`StatusSet`), `hp`, `poise`, `alive`, `invulnerable_ticks`, `hitstop_ticks`.

- **`configure(definition, id, faction, status_config, ticks_per_second)`** — полная настройка и сброс.
- **`tick(damage_system)`** — один боевой такт: модификаторы, статусы, i-frames, хитстоп, реген poise (после `poise_regen_delay` без попаданий и вне стана).
- **`apply_result(result)`** — снимает HP/poise, фиксирует `actual_damage`; при HP = 0 умирает и чистит статусы; при poise ≤ 0 — стаггер: стан 0,4 с и полное восстановление poise.
- **`can_act()`** — жив, без хитстопа, не в стане и не в заморозке. **`movement_multiplier()`** — замедление от охлаждения, 0 при `can_act() == false`.
- **`apply_knockback(distance, direction)`** — запускает отбрасывание: полная `distance` в метрах проходится за фиксированные `KNOCKBACK_DURATION_SECONDS` (0,12 с), расчёт раскладывает её на `knockback_per_tick`. Снос — принудительное смещение: работает через стан/заморозку/хитстоп. **`knockback_offset()`** — смещение текущего такта (ноль вне отбрасывания); контроллеры применяют его к позиции, стены удерживают на их уровне.
- **`heal(amount)`**, **`health_ratio()`**.

### `attack_definition.gd` — `AttackDefinition` (ресурс)

Статика одной атаки: `id`, `damage_type`, `base_damage`, `poise_damage`, флаги-теги `tags`, `hit_cooldown` (минимум секунд между повторными попаданиями по цели), `max_hits_per_target` (≤ 0 — без лимита), `knockback_distance` (дистанция отбрасывания в метрах; 0 — без толчка, направление даёт доставка), `status_applications: Array[StatusApplication]`. Кулдауны живут в действии, а не здесь.

### `status_application.gd` — `StatusApplication` (ресурс)

Одна запись «какой статус, сколько стаков» внутри атаки: `status`, `stacks`.

### `status_config.gd` — `StatusConfig` (ресурс)

Баланс статусов прототипа (секунды, конвертируются в такты): горение 5 урона/с/стак, 3 с, максимум 5 стаков; яд 2 урона/с/стак, 6 с, максимум 5; охлаждение 5% за стак, максимум 10, 4 с, заморозка на 10 стаках на 1 с; стан 0,4 с; кровотечение +5% входящего за стак, максимум 10, 4 с; тик DoT каждые 0,25 с. Значения совпадают с [GDD](gdd/03_combat.md).

### `status_set.gd` — `StatusSet`

Фиксированные массивы стаков, остатка тактов и `source_id` по `CombatTypes.Status`.

- **`apply(status, count = 1, source_id = -1)`** — добавляет стаки (с потолком), обновляет длительность; охлаждение на `freeze_at_stacks` превращается в заморозку.
- **`tick(owner, damage_system)`** — одна секунда расписания: по `dot_interval` наносит объединённый DoT через `DamageSystem.deal_status()` (горение — магический, яд — физический), затем уменьшает остатки и снимает истёкшие.
- **`has(status)`**, **`stacks_of(status)`**, **`movement_multiplier()`** (1 − стаки охлаждения × замедление), **`clear()`**.

### `modifier_definition.gd` — `ModifierDefinition` (ресурс)

Общая статика модификатора (один `Resource` на всех владельцев): `id`, `operations`, `duration` (секунды), `max_stacks`, `adds_stack_on_reapply`, `refreshes_duration`, `priority`, условия `required_attack_tags`, `required_target_status`, `target_hp_ratio_below` и опциональный `after_damage_handler: ModifierHandler`. Весь баланс — в `.tres`.

### `modifier_operation.gd` — `ModifierOperation` (ресурс)

Одна операция: `stat` (`CombatTypes.Stat`), `value`, маска типов урона `damage_type_mask` (биты физический/магический), `required_attack_tags` (операция работает только для атак с этими тегами). Аддитивные статы суммируются, множители перемножаются постепенно (`pow(value, stacks)`).

### `modifier_instance.gd` — `ModifierInstance`

Runtime одного модификатора на бойце: ссылка на определение, `source_id`, `stacks`, `remaining_ticks`, `sequence` (порядок получения для стабильной сортировки).

### `modifier_set.gd` — `ModifierSet`

Активные модификаторы бойца и лениво пересобираемый снимок статов.

- **`add(definition, source_id)`** — новый экземпляр или повторное наложение по `id` (стак/обновление длительности по флагам определения).
- **`remove(id)`**, **`tick()`** (истечение длительности).
- **`get_stats()`** — пересобирает `CombatStats` только при `stats_dirty`: полная пересборка в стабильном порядке (priority, затем sequence), безусловные операции уходят в статистики.
- **`apply_conditional(request, source, target, attack_tags)`** — на попадании прогоняет только условный список: теги атаки, статус цели, порог HP.
- **`notify_after_damage(source, target, actual_damage)`** — вызывает `after_damage` у обработчиков всех экземпляров.

### `combat_stats.gd` — `CombatStats`

Готовый снимок агрегированных статов бойца, массивы индексируются `CombatTypes.DamageType`: `flat_bonus`, `outgoing_additive`, `outgoing_multiplier`, `incoming_additive`, `defense`, `mitigation`, плюс `max_hp`, `max_poise`, `defense_constant`. Пересобирается только при изменении модификаторов.

### `modifier_handler.gd` — `ModifierHandler` (ресурс)

База особых поведений, которые не выражаются данными. Пока один хук: **`after_damage(source, target, actual_damage)`** — после фактического изменения HP.

### `damage_system.gd` — `DamageSystem`

Единая точка входа для прямых попаданий и урона статусов. Владеет реестром состояний: `register_combatant(state)`, `unregister_combatant(actor_id)`.

- **`deal(attack, source, target, result, scale = 1.0, knockback_direction = Vector2.ZERO)`** — отклоняет мёртвых, неуязвимых (i-frames) и союзные цели (`prevented = true`); собирает `DamageRequest` из статов источника и цели, кровотечения цели и условных модификаторов обеих сторон; считает через `DamageCalculator`; применяет результат; при `attack.knockback_distance > 0` толкает цель вдоль `knockback_direction` (не для DoT и не по мёртвым); ставит хитстоп (`hitstop_ticks`, по умолчанию 2); накладывает статусы атаки; шлёт `notify_after_damage`.
- **`deal_status(target, status, damage, source_id)`** — DoT без хитбокса: тег `DOT`, магический для горения, физический для яда.

### `hit_registry.gd` — `HitRegistry`

Правила повторных попаданий: ключ `(attack_instance_id, actor_id цели)`, сколько попаданий нанесено и следующий допустимый такт.

- **`register_hit(attack_instance_id, target_id, tick, cooldown_ticks, max_hits) -> bool`** — `true`, если попадание засчитано; `max_hits <= 0` — без лимита (кулдаун всё равно работает).
- **`hits_for()`**, **`clear_attack()`** (записи одной атаки удаляются вместе с ней), **`clear_target()`**, **`clear()`**.

### `hitbox_2d.gd` — `Hitbox2D` (`Area2D`)

Активная область атаки (ближний удар, снаряд, взрыв). Несёт `attack`, `source` (`CombatantState`), уникальный `attack_instance_id` (0 — без учёта повторов), `damage_scale`, боевой `combat_tick`. **`tick()`** сохранён для обычной проверки кешированных пересечений. Фазовая комната вызывает **`tick_current(shape, transform, space_state, simulation_tick)`**: один шаг часов на такт и прямой ограниченный запрос текущей геометрии, без кеша предыдущего обновления. Жертвы обрабатываются по ID; источник повторно проверяется перед каждым попаданием. Оба пути сохраняют фильтрацию фракций, мёртвых и i-frames, общий `HitRegistry` и `DamageSystem.deal`, включая направление отбрасывания. Автономного `_physics_process` нет. Мгновенный AoE — `deal_aoe(shape, transform, space_state)` и статический `query_hurtboxes()`. `end_attack()` снимает регистрацию и отключает дальнейшую доставку.

### `hurtbox_2d.gd` — `Hurtbox2D` (`Area2D`)

Пассивная область получения урона: несёт `combatant` (`CombatantState`), живёт на своём collision layer (бит 3; хитбоксы — бит 4), ничего не мониторит, HP не хранит.

---

## Герои (`src/heroes/`)

Отряд из ровно 3 героев на фиксированных тактах; активен всегда один, «карманные» герои продолжают тикать (кулдауны, статусы, i-frames, HP без изменений). Правила — в [GDD](gdd/02_heroes.md), параметры прототипа — в `data/heroes/hero_default.tres` и `data/heroes/party_default.tres`.

### `hero_definition.gd` — `HeroDefinition` (ресурс)

Статика героя поверх `CombatantDefinition`: `attack` и `skill` (`AttackDefinition`, включая дистанции отбрасывания: 0,8 м у атаки, 1,2 м у скилла), `attack_recovery` (0,35 с, автоатаки нет), `skill_cooldown` (3 с), `skill_duration` (0,3 с), `dash_distance` (3 м), `dash_duration` (0,18 с, i-frames на весь рывок), `dash_cooldown` (0,8 с).

### `hero_combat_state.gd` — `HeroCombatState`

`CombatantState` с машиной действий: `enum Action { IDLE, ATTACKING, SKILLING, DASHING }`, `action_ticks_left`, `skill_cooldown_left`, `dash_cooldown_left`, `dash_direction`. Кулдауны тикают каждый такт, в том числе в кармане.

- **`configure_hero(definition, id, status_config, ticks_per_second)`**.
- **`start_attack()` / `start_skill()` / `start_dash()`** — длительность из `HeroDefinition`, в тактах; рывок ставит i-frames на всё своё время и свой кулдаун.
- **`finish_skill()`** — кулдаун скилла стартует в такт выстрела.
- **`cancel_skill()`** — свап во время незаконченного каста отменяет скилл без траты кулдауна.
- **`dash_ticks()`**, **`_seconds_to_ticks()`** — перевод секунд в такты (минимум 1 такт).

### `hero_action_controller.gd` — `HeroActionController`

Фиксотактовый контроллер одного героя: владеет мировой позицией (метры), `facing`, `move_intent`; превращает намерения в действия.

- **Сигналы:** `attack_fired(attack, origin, direction)`, `skill_fired(attack, origin, direction)` — снаружи (хитбоксами или тестом) превращаются в реальные попадания; сам контроллер урон не доставляет.
- **`tick(active, damage_system)`** — один такт; при `active = false` (карман) состояние тикает, движения и действий нет. Движение разрешено во время перезарядки атаки и каста скилла; рывок перекрывает движение, последний такт рывка всё ещё несёт героя вперёд. Активное отбрасывание — принудительное смещение: оно перекрывает движение по намерению (в том числе «в кармане»), но не бегущий рывок (снос в полёте складывается с шагом рывка); стены удерживает view-адаптер.
- **`request_attack()`** — стреляет немедленно, если в IDLE и `can_act()`; дальше перезарядка гейтит следующее нажатие.
- **`request_skill()`** — только из IDLE, без кулдауна и с `can_act()`.
- **`request_dash()`** — из IDLE или ATTACKING (dash-cancel recovery), без кулдауна; направление — `move_intent` или `facing`.

### `party_config.gd` — `PartyConfig` (ресурс)

Состав и баланс свапа: `heroes: Array[HeroDefinition]` (ровно 3, один и тот же ресурс может занимать несколько слотов), `swap_cooldown` (1 с). Файл: `data/heroes/party_default.tres`.

### `party_controller.gd` — `PartyController`

Фиксотактовый контроллер отряда. Сигналы `hero_activated(index)`, `hero_deactivated(index)`.

- **`setup(config, damage_system, status_config, first_actor_id, start_position, ticks_per_second)`** — строит состояния и контроллеры трёх героев и регистрирует их в `DamageSystem`.
- **`apply_input(frame)`** — применяет один `HeroInputFrame`: намерение движения и одноразовые действия. Не продвигает симуляцию.
- **`tick()`** — сначала кулдаун свапа, затем по такту на каждого героя (только активный исполняет действия).
- **`request_swap_to(index)`** — отказывает при кулдауне, свапе на себя или на мёртвого; незаконченный скилл отменяется, рывок продолжается в кармане.
- **`request_swap_next()` / `request_swap_prev()`** — обход по кругу, пропуская мёртвых.
- Делегирует `set_move_intent`, `request_attack`, `request_skill`, `request_dash` активному герою. **`party_alive()`**, **`active_state()`**, **`active_controller()`**.

### `hero_input_frame.gd` — `HeroInputFrame`

Чистые данные одного такта ввода: `sequence`, `move` и битовая маска `pressed` (`Action`). Методы `press(action)` и `is_pressed(action)`. Не содержит ссылок на узлы, позиции или урон; одинаково подходит для локального и будущего сетевого ввода.

### `hero_input.gd` — `HeroInput` (статический)

Программная регистрация действий в `InputMap` (project.godot не трогается). Действия: `hero_move_*` (WASD + левый стик), `hero_attack` (ЛКМ / X), `hero_skill` (ПКМ / Y), `hero_dash` (Space / B), `hero_swap_1/2/3` (клавиши 1/2/3), `hero_swap_next/prev` (крестовина вверх/вниз). Дефолты добавляются только в действия без событий — переназначение в настройках не ломается. **`move_intent()`** — вектор движения из `InputMap`.

### `hero_input_node.gd` — `HeroInputNode` (`Node`)

Раз в `_physics_process` читает `InputMap`, создаёт `HeroInputFrame` с монотонным `sequence` и испускает `frame_ready(frame)`. Не владеет отрядом и не вызывает `tick()`. В `dungeon_preview` обработчик сигнала сохраняет кадр; фазовый владелец применяет его и вызывает `PartyController.tick()` один раз до синхронизации тела героя и снимка врагов.

### `remote_hero_view.gd` — `RemoteHeroView` (`Node2D`)

Presentation-only реплика героя для будущего клиента. **`bind(state)`** связывает отображаемые HP/действие, **`apply_snapshot(position_m, facing, is_active)`** напрямую применяет позицию в метрах, направление и видимость. Не является `CharacterBody2D`, не создаёт `CollisionShape2D`/`Hurtbox2D`, не хранит контроллер и не пишет в авторитетное состояние. Интерполяция и `ReplicaWorld` относятся к следующим этапам.

---

## Данные (`src/dungeon/`)

### `dungeon_types.gd` — `DungeonTypes` (статический)

Общие перечисления и хелперы генератора.

- **Перечисления:**
  - `Dir` (NORTH, EAST, SOUTH, WEST);
  - `RoomType` (START, COMBAT, SHOP, BOSS);
  - `Terrain` (LAND, WATER);
  - `Structure` (NONE, BRIDGE_H, BRIDGE_V, STAIRS);
  - `BorderStyle` (TREES, WATER, CLIFFS).
- **Константы:**
  - `DIR_VECTORS` — вектор шага по `Dir`;
  - `AROUND_8` — смещения 8 соседей.
- **Хелперы:** `opposite(dir)`, `is_horizontal(dir)`, `room_type_name(type)`, `dir_name(dir)`.

### `dungeon_config.gd` — `DungeonConfig` (ресурс)

Настройки уровня данжа. Файл: `data/dungeon/default_dungeon.tres`.

- `biome` — биом по умолчанию.
- `min_rooms`, `max_rooms` — сколько комнат всего (7–11).
- `shop_chance` — шанс лавки.
- `extra_connection_chance` — шанс петли между соседними комнатами.
- `start_room_size`, `combat_room_min/max`, `shop_room_size`, `boss_room_size` — размеры комнат в клетках.
- `door_width` — ширина двери.
- `max_room_attempts` — попыток на комнату (последняя плоская).

### `biome_data.gd` — `BiomeData` (ресурс)

Параметры генерации и вида одного биома. Файлы: `data/biomes/*.tres`.

| Группа | Параметры |
|---|---|
| **Border** | `border_style`, `border_thickness`, `border_wobble`, `border_props` (чем засаживать лесную границу) |
| **Elevation** | `max_level`, `elevation_amount` (доля поднятой площади), `high_ground_amount` (доля уровня 2), `elevation_frequency`, `min_plateau_cells` |
| **Water** | `river_chance`, `river_width`, `lake_amount`, `lake_frequency`, `min_lake_cells`, `bridge_width`, `max_bridge_length` |
| **Vegetation** | `lush_amount`, `vegetation_frequency`, `props` (список `PropRule`) |
| **Rendering** | `tile_theme`, `tint` (оттенок-заглушка) |

- **`load_all(folder = "res://data/biomes") -> Array[BiomeData]`** (статическая) — все биомы папки, по имени файла. Так просмотрщик и тесты подхватывают новые биомы без правки кода.

### `prop_def.gd` — `PropDef` (ресурс)

Описание одного декоративного объекта (дерево, камень, кувшинка). Файлы: `data/props/*.tres`.

- `id` — по нему тема находит тайл.
- `size` — пятно в клетках; якорь — нижняя левая клетка, пятно растёт вверх и вправо.
- `blocking` — блокирует ли нижний ряд (ствол или основание).
- `placement` — `LAND` или `WATER`.
- `collision_size`, `collision_lift` — физический коллайдер основания в метрах.

### `prop_rule.gd` — `PropRule` (ресурс, вложенный в биом)

Как часто биом разбрасывает один пропс.

- `prop` — какой `PropDef`.
- `density` — шанс на подходящую клетку.
- `clustering` — 0: равномерно, 1: только рощами по шуму растительности.

### `dungeon_data.gd` — `DungeonData`

Результат генерации: граф комнат и карты всех комнат.

- **Поля:**
  - `run_seed`, `biome`;
  - `rooms: Array[RoomData]`;
  - `start_index`, `boss_index`, `shop_index` (−1 без лавки).
- **`room_at(grid_pos)`** — комната по позиции на сетке.
- **`neighbor(room, dir)`** — комната за дверью или `null`.

### `room_data.gd` — `RoomData`

Одна комната графа.

- `index`, `grid_pos` — номер и позиция на сетке данжа.
- `type: RoomType`.
- `size` — в клетках.
- `depth` — дверей до старта.
- `neighbors: Dictionary[Dir → индекс комнаты]`.
- `room_seed` — подсид комнаты.
- `map: RoomMap` — карта комнаты.
- `attempts` — с какой попытки она собралась.

### `room_map.gd` — `RoomMap`

Сетка одной комнаты — главный формат данных. Её читают рендер, коллизии и тесты. Не зависит от отрисовки.

**Слои** (`PackedByteArray`, индекс `y * width + x`):

| Слой | Смысл |
|---|---|
| `level` | Уровень высоты 0–2 |
| `terrain` | Суша или вода (`Terrain`) |
| `structure` | Мост или лестница (`Structure`) |
| `wall` | Граница комнаты, непроходима |
| `keep_flat` | Ровная сухая земля: подходы к дверям, центр |
| `lush` | Густая трава (только вид) |
| `path` | Главные пути центр → двери |
| `road` | Дорога: главные пути шириной 2 на ровной сухой земле |
| `occupied` | Под пятном пропса |
| `blocked` | Заблокировано пропсом |

**Объекты:**
- `doors: Array[Door]`. У двери есть `dir`, `edge_cells` (клетки на краю комнаты), `corridor` (клетки коридора через границу), `inner` (первая клетка внутри).
- `center` — клетка-фокус комнаты.
- `stairs` — верхний левый угол каждого блока лестницы 2×2.
- `props: Array[PlacedProp]` — у каждого `prop` и якорная клетка `cell`.

**Адресация:** `cell_count()`, `idx(c)`, `cell(i)`, `in_bounds(c)`, `level_at(c)`.

**Вопросы к клетке:** `is_water`, `is_land`, `is_bridge`, `is_cliff_face` (на клетке нарисован обрыв).

**Движение:**
- `is_ground(c)` — проходимый рельеф без учёта пропсов.
- `is_walkable(c)` — то же плюс пропсы.
- `can_cross(from, dir)` — правило рельефа для шага: тот же уровень, или столбец лестницы, или мост вдоль оси. Через обрыв — никогда.
- `can_step(from, dir)` — `can_cross` плюс пропсы.

**Поиск:**
- `compute_regions()` — метки связных областей.
- `reachable_from(start)` — что достижимо из клетки.
- `find_path(from, to)` — кратчайший путь (BFS).
- `nearest_open_land(target)` — ближайшая сухая клетка, низины в приоритете.
- `key_cells()` — центр и внутренние клетки дверей.
- `door(dir)` — дверь с нужной стороны.

**Прочее:** `checksum()` — хеш всей карты, для теста детерминизма.

---

## Генерация (`src/dungeon/generation/`)

### `dungeon_generator.gd` — `DungeonGenerator` (статический)

Точка входа: строит граф, затем карту каждой комнаты.

- **`generate(config, run_seed, biome = null) -> DungeonData`** — без `biome` берётся `config.biome`. Каждой комнате выдаётся подсид `hash([run_seed, index])`.

### `layout_generator.gd` — `LayoutGenerator` (статический)

Граф комнат на сетке.

- **Что строит:**
  - дерево обычных комнат, где новая комната касается только родителя;
  - петли с шансом `extra_connection_chance`;
  - босс в самом глубоком тупике (не у старта);
  - лавка в отдельном тупике не у босса;
  - размеры комнат по типу.
- **`generate(config, rng) -> DungeonData`** — комнаты и связи без карт. До 64 повторов, если размещение не удалось.

### `room_generator.gd` — `RoomGenerator` (статический)

Конвейер одной комнаты и повторы при неудаче.

- **`generate(room, config, biome) -> RoomMap`:**
  - до `max_room_attempts` попыток;
  - у каждой свой сид;
  - чем дальше попытка, тем спокойнее рельеф;
  - последняя плоская.
- **`build(room, config, biome, rng, damping, flat) -> RoomMap`** — одна попытка: граница → защита центра → рельеф → центр → связность ключевых клеток → связность всей земли → декор. Возвращает `null`, если связать не удалось. Проверку делает `generate`.

### `terrain_shaper.gd` — `TerrainShaper` (статический)

Сырой рельеф и его чистка.

- `build_border(map, room, config, biome, rng)` — граница с шумовым краем и двери (коридоры или мосты), `keep_flat` у дверей.
- `protect_disc(map, center, radius)` — пометить диск как ровную сухую землю.
- `shape(map, room, config, biome, rng, damping, flat)` — высоты, озёра, река, затем `cleanup`.
- `cleanup(map, biome) -> bool` — повторять правила форм до стабильности:
  - защищённые клетки;
  - отступы от воды и между уровнями;
  - блоки 2×2 для плато, воды и суши;
  - щели;
  - мелкие пруды, острова и плато.

  Возвращает `false`, если не сошлось за 16 проходов.
- `settle(map, biome)` — чистка, которая только опускает. Используется после прорезания прохода.
- `border_depth(biome)`, `door_center(map, dir)` — геометрия границы и дверей.

### `terrain_connector.gd` — `TerrainConnector` (статический)

Связность комнаты.

- `connect_keys(map, biome, rng) -> bool` — жадно добавляет самую дешёвую связь (мост, лестница или проход), пока все ключевые клетки не окажутся в области центра. `false`, если не удалось.
- `connect_everything(map, biome, rng) -> bool` — делает достижимой каждую клетку, по которой можно ходить:
  - крупные области получают мост, лестницу или проход;
  - мелкие и несвязуемые убираются: возвышенность опускается, низина становится прудом или частью границы;
  - `false`, если не сошлось за 80 шагов.
- `stairs_intact(map, top) -> bool` — сохранила ли лестница нужную форму. Используется валидатором и после изменений рельефа: погнутые лестницы снимаются.
- `stairs_fit(map, top) -> bool` — можно ли поставить лестницу 2×2 с верхним левым углом в `top`.
- Внутренний класс `Link` — кандидат связи: вид, начало, направление, длина, целевая область, цена.

### `room_decorator.gd` — `RoomDecorator` (статический)

Декор связанной комнаты.

- **`decorate(map, room, biome, rng)`:**
  - главные пути в `map.path` (поиск предпочитает клетки, где может лечь дорога);
  - дороги в `map.road`: кисть 2×2 по путям, только на ровной сухой земле, обрывки короче 6 клеток убираются;
  - резерв (пути с обочинами, поляна, двери, концы мостов и лестниц);
  - густая трава;
  - лесная граница;
  - пропсы по правилам биома;
  - открытие карманов: если пропсы замкнули клочок земли, мешающие пропсы убираются.
- **`clearing_radius(room) -> float`** — радиус поляны в центре по типу комнаты.

### `room_validator.gd` — `RoomValidator` (статический)

Инварианты готовой комнаты: достижимость, формы рельефа, мосты, лестницы, пропсы, дороги. Подробный список — в [dungeon_generation.md](dungeon_generation.md#26-проверка-roomvalidator).

- **`validate(map) -> PackedStringArray`** — список ошибок; пустой значит комната корректна. Используется генератором (отбраковка попытки) и тестами.

### `grid_utils.gd` — `GridUtils` (статический)

Общие помощники для работы с сеткой.

- `components(mask, size)` — 4-связные компоненты маски.
- `quantile(values, q)` — порог по доле: так «доля площади» переводится в порог шума.
- `shuffled_indices(count, rng)` — перемешанные индексы (Фишер–Йейтс, детерминированно).
- `make_noise(seed, frequency, octaves)` — настроенный `FastNoiseLite` (simplex fBm).

---

## Коллизии (`src/dungeon/physics/`)

### `room_collision.gd` — `RoomCollision` (статический)

Физика комнаты из `RoomMap`: свой набор стен на каждый уровень, обрыв всегда стена, между уровнями только лестницы.

- **`wall_segments(map, level, face_depth) -> PackedVector2Array`** — отрезки стен для стоящих на `level`, парами точек в метрах.
  - Комната сэмплируется с шагом в полклетки.
  - `face_depth` — глубина нарисованного обрыва, на которой останавливается верхний уровень (0.5 для текущих тайлов).
- **`prop_boxes(map, level) -> Array[Rect2]`** — коллайдеры оснований блокирующих пропсов, в метрах.
- **`build_2d(map, pixels_per_meter, face_depth) -> Node2D`** — готовые `StaticBody2D`, по одному на уровень, на слое `layer_bit(level)`.
- **`layer_bit(level)`** — бит физического слоя уровня (`1 << level`).
- **`max_level(map)`** — самый высокий уровень в комнате.

**Кто использует:** просмотрщик, тест ходьбы, отладочный слой.

---

## Отрисовка (`src/dungeon/render/`)

### `blob_autotile.gd` — `BlobAutotile` (статический)

Автотайлинг по 8 соседям (47 форм).

- **Биты маски:** `N`, `NE`, `E`, `SE`, `S`, `SW`, `W`, `NW`. `FULL` — все соседи заняты.
- **`LAYOUT_11X5`** — маска → координаты тайла в стандартной раскладке 11×5 (снята с `Grass.png` базового пака).
- **`canonical(mask)`** — убирает угловые биты без обоих прилегающих краёв.
- **`mask_at(solid, size, c, outside)`** — каноническая маска клетки. Клетки за краем считаются как `outside`.

### `blob_sheet.gd` — `BlobSheet` (ресурс, вложенный в тему)

Один лист с 47 blob-формами: земля, дорога или обрыв.

- `texture` — текстура листа.
- `layout_origin` — где на листе начинается раскладка 11×5 (у травы и снега Sorry pack — ряд 5).
- `layout_overrides` — маска → абсолютные координаты там, где лист отличается от стандарта.
- `plain_variants`, `plain_variant_chance` — варианты сплошного тайла для обычных клеток.
- `lush_variants` — варианты для клеток густой травы.
- **`tile(mask) -> Vector2i`** — координаты тайла для маски.
- **`all_tiles()`** — все тайлы листа, для сборки `TileSet`.

### `prop_atlas.gd` — `PropAtlas` (ресурс)

Текстура со спрайтами пропсов. Файлы: `data/themes/atlases/*.tres`.

- `texture`.
- `tiles` — `PropDef.id` → прямоугольник в тайлах. Размер прямоугольника равен пятну пропса.

### `tile_theme.gd` — `TileTheme` (ресурс)

Какими тайлами рисуется комната. Файлы: `data/themes/*.tres` (`meadow`, `pine`, `cherry`, `winter`).

| Группа | Параметры |
|---|---|
| Общее | `texture_tile_size` — размер тайла в исходном арте (свойство картинки, не мира) |
| Вода | `water_texture`, `water_frames`, `water_fps` — анимация |
| Земля | `land: BlobSheet` — суша поверх воды; `road: BlobSheet` — накладка дороги (`null` = без дорог) |
| Обрывы | `hills: BlobSheet`, `stairs_origin` (блок лестницы 2×2), `cliff_face_depth` (глубина нарисованного склона) |
| Мосты | `bridge_texture`, `bridge_vertical`, `bridge_horizontal` (начало, середина, конец) |
| Пропсы | `prop_atlases: Array[PropAtlas]` — атласы, в которых ищется `PropDef.id` по порядку |

### `tile_set_factory.gd` — `TileSetFactory` (статический)

Собирает `TileSet` из `TileTheme` во время выполнения и кэширует его.

- **`get_tile_set(theme) -> TileSet`:**
  - источники `Source`: WATER (анимированная), LAND, HILLS, BRIDGE, ROAD;
  - атлас пропсов k — источник `PROPS + k`;
  - многоклеточные пропсы сдвинуты так, что растут от нижней левой клетки.
- **`find_prop(theme, id) -> [source, rect]`** — где в теме лежит спрайт пропса; source = −1, если нигде.

### `room_tile_renderer.gd` — `RoomTileRenderer` (`Node2D`)

Рисует `RoomMap` слоями `TileMapLayer`: вода → суша → дороги уровня 0 → мосты → для каждого уровня его обрывы и дороги → `actors`.

- **`render(map, biome)`:**
  - перерисовывает комнату;
  - выбирает тайлы по маскам соседей из листов темы, а варианты — по хешу клетки (стабильно);
  - масштабирует узел так, что клетка = `WorldUnits.CELL_PIXELS`.
- **`actors: Node2D`** — y-sort контейнер со слоем пропсов. Персонажи добавляются сюда, чтобы правильно сортироваться с деревьями. Переживает перерисовку.
- **`props_layer: PropsLayer`** — слой пропсов текущей комнаты.
- **`local_pixels_per_meter`** — сколько локальных пикселей в метре (для коллизий и персонажей внутри узла).
- **`add_room_node(node)`** — добавить узел текущей комнаты (коллизии, триггеры). Освобождается при смене комнаты.
- **`clear()`** — убрать всё от текущей комнаты; персонажи остаются.

### `props_layer.gd` — `PropsLayer` (`TileMapLayer`)

Слой пропсов с y-sort и затуханием.

- **`add_prop(anchor, source, atlas)`** — поставить пропс и запомнить границы его спрайта.
- **`update_fade(feet, height)`** — пропсы, за которыми стоят персонажи (внутри спрайта и выше его основания), рисуются с прозрачностью `FADE_ALPHA`. Затухание снимается, когда персонаж отходит.

---

## Импорт биома (`src/dungeon/import/`)

Подробно о форматах и эвристиках — [biome_import.md](biome_import.md).

### `blob_scanner.gd` — `BlobScanner` (статический)

Распознаёт формы автотайлинга по пикселям листа.

- **`scan(image, tile_size, region, exclude)`** возвращает `Result`:
  - `layout` — маска → клетка первого тайла с этой формой;
  - `missing` — каких из 47 масок нет;
  - `plain`, `lush` — варианты полного тайла;
  - `fill` — цвет заливки.
- **`to_origin_and_overrides(layout)`** — переводит раскладку в `layout_origin` + `layout_overrides` для `BlobSheet`.
- **Константы порогов:** `SURFACE_DISTANCE`, `SIDE_SHARE`, `MIN_OPAQUE`, `DETAIL_DISTANCE`, `LUSH_SHARE`, `SEAM_SHARE`.

### `prop_slicer.gd` — `PropSlicer` (статический)

Находит спрайты пропсов на листе.

- **`slice(image, tile_size)`** — спрайты сверху вниз и слева направо. У каждого (`Sprite`):
  - `rect` — прямоугольник в тайлах;
  - `coverage` — доля непрозрачных пикселей в нижнем тайле;
  - `base_width` — ширина основания;
  - `gap` — зазор под основанием.
- **Константы:** `SOLID_COVERAGE` (порог блокировки по умолчанию), `BASE_ROWS`.

### `biome_importer.gd` — `BiomeImporter` (статический)

Собирает биом из папки.

- **`run(folder, out)`** — читает `biome.cfg` (или угадывает листы по именам файлов), сканирует листы, нарезает пропсы, строит тему, атласы, пропсы, правила и биом. Ничего не записывает. Возвращает `Result`: ресурсы, строки отчёта `report` и ошибки `errors`.
- **`save(result, out)`** — пишет файлы в `out` (по умолчанию `res://data`) и удаляет устаревшие файлы пропсов этого биома.
- Существующий биом в `out` сохраняет параметры генерации. Новый копирует их из `template`.

---

## Враги (`src/enemies/`)

Подробно — в [enemy_ai.md](enemy_ai.md). Враги подключены к просмотрщику: `dungeon_preview` спавнит 3 `BasicEnemy` в каждой комнате на общем `DamageSystem`.

### `enemy_definition.gd` — `EnemyDefinition` (ресурс)

Балансные параметры одного типа врага: только метры и секунды, пиксели получаются в момент отрисовки. Файл: `data/enemies/basic_enemy.tres`.

- `display_name` — имя.
- `speed` — скорость, м/с.
- `radius` — радиус коллизии, м.
- `detection_range` — с какого расстояния враг замечает героя, м.
- `attack_range` — с какого расстояния он останавливается и начинает телеграф атаки, м.
- `attack_damage`, `poise_damage` — урон HP и poise одного удара.
- `attack_knockback` — дистанция отбрасывания удара, м (0,5; 0 — без толчка).
- `telegraph_duration` — неподвижный замах перед ударом, с.
- `attack_cooldown` — пауза между ударами, с.

### `room_navigation.gd` — `RoomNavigation` (`NavigationRegion2D`)

Навмеш одной комнаты, построенный из проходимых клеток `RoomMap` (не из тайлов), в локальных пикселях узла.

- **`build_2d(map, pixels_per_meter) -> RoomNavigation`** — каждая проходимая клетка становится выпуклым четырёхугольником. По ребру, где `RoomMap.can_cross()` разрешает шаг, квадрат доходит до границы клетки и соседние квадраты склеиваются в `NavigationServer2D`; где шаг запрещён (обрывы, бока мостов, блокирующие пропсы, стены), квадрат ужимается на зазор `GAP_FRACTION` (0.15 клетки) — больше маржи сервера, поэтому стороны не соединяются. Мосты, лестницы и уровни так следуют тем же правилам, что и персонажи (`RoomCollision`).

### `basic_enemy.gd` — `BasicEnemy` (`CharacterBody2D`)

Сборка первого врага ближнего боя: собственные runtime-компоненты, `CombatantState`, физическое тело и представление. `BasicEnemy.State` — совместимое представление автомата `EnemyBrain.State { IDLE, CHASE, TELEGRAPH, COOLDOWN }`:

- `IDLE` стоит; при герое ближе `detection_range` — `CHASE`;
- `CHASE` идёт к герою по своему `NavigationAgent2D`; вне радиуса — обратно в `IDLE`, в `attack_range` — `TELEGRAPH`;
- `TELEGRAPH` стоит неподвижно `telegraph_duration`, затем бьёт и уходит в `COOLDOWN`;
- `COOLDOWN` стоит `attack_cooldown`, затем выбирает следующее состояние по дистанции.

- **Поля:** `definition: EnemyDefinition`, `map: RoomMap`, `pixels_per_meter`, `level` (уровень клетки под ногами, определяет `collision_mask`), `state` (read-only для наблюдателей), `combat: CombatantState` (read-only, появляется только с `damage_system`), `damage_system: DamageSystem` (инжектится владельцем комнаты), `status_config` (по умолчанию `StatusConfig.new()`), `last_result` — переиспользуемый `DamageResult` последнего удара (read-only).
- **`enter_room(room_map, local_pixels_per_meter, cell, heroes, actor_id)`** — поставить в центр клетки, задать список героев и зарегистрировать бойца с ID, выданным `ActorIdAllocator`. **`set_targets(heroes)`** меняет список без пересоздания комнаты. **`meters()`**, **`cell()`** — позиция в метрах и клетка под ногами.
- **`tick()`** — полный такт одиночного врага, сохранённый для standalone-тестов. Preview вызывает только **`prepare_tick(context)`**, **`decide_tick(context)`**, **`plan_tick(context)`**, **`move_tick(context)`**, **`execute_tick(context)`**: каждую фазу всей группе до следующей, с защитой от повторного выполнения по tick/epoch. Автономного `_physics_process` нет.
- Удар не трогает HP сам: `EnemyMeleeAttack.strike()` отдаёт попадание в `DamageSystem.deal()` с собственным `CombatantState` (ENEMY) и боевым состоянием героя, которое герой обязан отдать через свойство `combatant_state`; направление отбрасывания — от тела врага к герою, дистанция — `definition.attack_knockback`. После телеграфа дистанция и уровень рельефа героя перепроверяются; мёртвых и i-frames отсекает сам `DamageSystem`. Без инжектированного `damage_system` боевого состояния нет и удар — no-op.
- Стан, заморозка и хитстоп останавливают весь автомат через `CombatantState.can_act()`. Все боевые таймеры — фиксированные 60 Гц такты, а не `delta`.
- Стены обходятся двояко: `NavigationAgent2D` строит путь по навмешу, `move_and_slide` страхует остатки на слое уровня `RoomCollision`. Логика — в `tick()`, `_process` только рисует состояние (цвет корпуса, кольцо телеграфа).

### `enemy_brain.gd` — `EnemyBrain` (`RefCounted`)

Чистый автомат одного врага. `reset()` очищает состояние и таймеры. `tick(distance_m, detection_range_m, attack_range_m, windup_ticks, can_act = true)` выдаёт `NONE`, `CHASE` или `STRIKE`; состояние и длительности принадлежат этому экземпляру. Входы — метры и фиксированные такты, без узлов, физики и пикселей. После исполнения `STRIKE` владелец вызывает `finish_strike(recovery_ticks)`, включая случай промаха: до этого обработчики урона видят `TELEGRAPH`, затем начинается полный cooldown.

### `enemy_perception.gd` — `EnemyPerception` (`RefCounted`)

Владеет копией списка кандидатов и выбранным узлом `target`. `set_targets()` заменяет список и очищает выбор. `select_target()` сохраняет прежнее правило ближайшего живого видимого узла; прямой видимости через геометрию пока нет. `target_local()`, `distance_m()`, `target_level()` и `target_combat_state()` адаптируют координаты и боевое состояние для сборки и исполнителя удара.

### `enemy_navigation.gd` — `EnemyNavigation` (`RefCounted`)

`chase_velocity()` получает принадлежащий телу `NavigationAgent2D` и возвращает скорость в локальных пикселях в секунду, переводя глобальную следующую точку пути через родителя. Хранит направление `facing`, но не перемещает тело и не владеет узлом агента. Avoidance и новая политика перепрокладки не включаются на R1.

На R2 `chase_velocity_to()` принимает захваченную позицию цели в локальных пикселях; игровой план не перечитывает уже изменившуюся позицию узла.

### `enemy_melee_attack.gd` — `EnemyMeleeAttack` (`RefCounted`)

Владеет собственными `AttackDefinition` и переиспользуемым `DamageResult`. `configure(definition)` копирует параметры физической ближней атаки, не изменяя общий ресурс. `strike()` сохраняет прежние проверки боевого состояния цели, дальности и уровня перед `DamageSystem.deal()`. Отказ до вызова боевого ядра оставляет предыдущий `last_result`, как до декомпозиции.

### Контекст и значения комнаты (`enemy_room_context.gd`, `enemy_room_snapshot.gd`, `enemy_actor_sample.gd`)

`EnemyRoomContext` владеет tick/epoch и отдельным реестром ID → узел. `begin_tick()` начинает новый кадр, `capture_actor()` копирует значения живого актёра, `finish_capture()` публикует общий снимок в порядке ID. `reset_room()` меняет epoch и очищает прежние данные; `is_current()`/`resolve_actor()` отсекают устаревшие кадры и удалённые узлы.

`EnemyRoomSnapshot` содержит tick, epoch и массив `EnemyActorSample`. Значения актёра — ID, позиция в метрах, уровень, радиус, фактическая скорость, живость, доступность и фракция; ссылок на узлы/физические RID в снимке нет. `EnemyPerception.select_snapshot()` выбирает цель по этим значениям, а исполнитель удара проверяет её актуальную геометрию через реестр. Снимок неизменяем по соглашению в пределах фазы.

---

## Отладка (`scenes/debug/`)

### `dungeon_preview.tscn` + `dungeon_preview.gd`

Главная сцена проекта: просмотрщик данжа и играбельный превью-бой.

- **Что делает:**
  - генерирует данж и рисует текущую комнату;
  - строит её коллизии и навмеш;
  - водит отряд из 3 героев (`data/heroes/party_default.tres`) через общий `DamageSystem`/`StatusConfig`/`HitRegistry`: `HeroInputNode` драйвит `PartyController`, каждый герой получает `CombatHeroView`, видим только активный;
  - спавнит 3 `BasicEnemy` (`data/enemies/basic_enemy.tres`) на проходимых клетках не ближе 4 клеток к точке входа; мёртвые враги усыхают и исчезают;
  - атака героя — короткоживущая дуга-`Hitbox2D` перед героем, скилл — мгновенный круг вокруг него; обе живут несколько физических тактов и считаются через общий `HitRegistry`; попадания отбрасывают цель (дистанции героя — в `data/heroes/hero_default.tres`, 0,8/1,2 м; удар врага берёт свою дистанцию из `EnemyDefinition.attack_knockback`, 0,5 м);
  - при гибели активного героя управление автоматически переходит к следующему живому;
  - переходит между комнатами через двери, пересобирая бой (спавн врагов, позиции героев);
  - рисует отладочный HUD: панель отряда (имя, HP, статусы), строку кулдаунов и числа живых врагов, миникарту графа, информацию о комнате и герое, FPS и время кадра;
  - трясёт камеру при потере HP героем (отключается `--no-shake`).
- **Клавиши:**
  - `WASD` — ходьба;
  - `ЛКМ` — атака, `ПКМ` — скилл, `Space` — рывок;
  - `1/2/3` — прямой свап героя, крестовина вверх/вниз — свап по кругу;
  - `F` — камера за героем;
  - `R` — новый seed;
  - `B` — биом;
  - стрелки — прыжок через дверь;
  - `Tab` — следующая комната;
  - `O` — отладочный слой;
  - колесо мыши — масштаб.
- **Аргументы командной строки** (после `--`):
  - `--seed=N`;
  - `--biome=<id>` — любой биом из `data/biomes`, или путь к файлу биома (`user://…/x.tres`) — удобно смотреть результат импорта, не добавляя его в игру;
  - `--room=N|boss|shop`;
  - `--hero=x,y`;
  - `--follow`;
  - `--overlay`;
  - `--no-shake` — выключить тряску камеры;
  - `--screenshot=файл.png` — снять кадр и выйти (в headless пропускается с предупреждением).
- Внутренние классы: `Minimap` (рисует граф комнат), `Strike` (жизненный цикл транзитного хитбокса), `DyingEnemy` (усыхание трупа).

### `combat_hero_view.gd` — `CombatHeroView` (`CharacterBody2D`)

Сцена-адаптер, связывающий один слот `PartyController` с комнатой.

- **`bind(state, controller)`** — привязать `HeroCombatState` и `HeroActionController`; хёртбокс героя (`Hurtbox2D`) несёт его `CombatantState`.
- **`enter_room(room_map, local_pixels_per_meter, cell)`** — поставить героя в центр клетки и синхронно снапнуть вид.
- **`sync_physics()`** зеркалит позицию контроллера (метры) в пиксели через `move_and_slide` (стены `RoomCollision`), возвращает фактическую позицию в контроллер и обновляет proxy/скорость. При `room_owns_physics = true` фазовая комната вызывает его до снимка, а автономный callback обновляет только представление. Вне этого режима сохранена автономная синхронизация с приоритетом 1. Карманные виды не двигаются и не возвращают свои старые позиции в контроллеры.
- Виден только активный герой; карманные герои скрыты, но продолжают тикать через `PartyController`. Спрайт — 4 направления по 4 кадра из Sprout Lands; при потере HP — вспышка, при смерти — серый кадр.
- Внутренний класс `HeroProxy` (`Node2D`): стенд-ин «позиция + боевое состояние героя», за которым следят `BasicEnemy` (свойство `combatant_state`). Активный вид присваивает прокси себя, поэтому враги автоматически перенацеливаются при свапе.
- **`cell()`**, **`meters()`**, **`height`** — клетка под ногами, позиция в метрах и высота для затухания пропсов.

### `room_debug_overlay.gd` — `RoomDebugOverlay` (`Node2D`)

Отладочный слой поверх комнаты.

- **Что рисует:**
  - граница;
  - недостижимая земля;
  - главные пути;
  - лестницы;
  - двери;
  - центр;
  - стены и коллайдеры каждого уровня (уровень героя ярко).
- **`show_map(map, face_depth)`** — показать комнату.
- **`hero_level`** — какой уровень подсветить.

### `test_hero.gd` — `TestHero` (`CharacterBody2D`)

Отладочный персонаж для физических проверок данжа (сейчас — `test_room_walk.gd`). Боевой превью-бой ходит через `CombatHeroView`.

- **Параметры:**
  - `speed` — 5 м/с;
  - `radius` — круг 0.3 м;
  - `height` — 1 м, для затухания пропсов.
- **Уровень:** `level` берётся из клетки под ногами. `collision_mask` — слой этого уровня.
- **Управление:** `WASD` при `use_keyboard`, иначе направление из `steer` (так им управляют тесты).
- **`enter_room(map, local_pixels_per_meter, cell)`** — поставить в центр клетки комнаты.
- **`cell()`** — клетка под ногами. **`meters()`** — позиция в метрах.
- **Спрайт:** персонаж из Sprout Lands, 4 направления по 4 кадра.

---

## Тесты (`tests/`)

Все тесты — скрипты `SceneTree`, запускаются без окна и возвращают код выхода 1 при ошибке. Биомы берутся все из `data/biomes` (`BiomeData.load_all`).

### `test_dungeon_generator.gd`

Прогоняет генератор на многих сидах для каждого биома.

- **Граф:**
  - число комнат в пределах;
  - один старт и один босс;
  - босс — самый дальний тупик;
  - не больше одной лавки, и она тупик;
  - связи симметричны и совпадают с сеткой.
- **Комнаты:**
  - карта есть;
  - двери соответствуют связям;
  - `RoomValidator` без ошибок.
- **Детерминизм:** одинаковый seed даёт одинаковые карты.
- **Статистика:** доля лавок, сборка с первой попытки, лестницы, мосты, время.

```bash
godot --headless --path . -s res://tests/test_dungeon_generator.gd -- --seeds=60
```

### `test_room_walk.gd`

Физическая проверка на настоящих коллизиях.

- `TestHero` идёт по пути из центра к каждой двери и выходит через неё.
- На обрывах герой не может спуститься сверху и залезть снизу.

```bash
godot --headless --fixed-fps 60 --path . -s res://tests/test_room_walk.gd -- --seeds=10
```

`--fixed-fps` гоняет физику без ожидания реального времени.

### `test_actor_id_allocator.gd`

Проверяет последовательную выдачу ID, непрерывные блоки, отсутствие повторного использования и настраиваемый первый ID.

```bash
godot --headless --path . -s res://tests/test_actor_id_allocator.gd
```

### `test_camera.gd`

Проверяет, что в режиме слежения видимая область камеры не выходит за границы комнаты, включая крайние позиции героя, зум и комнаты меньше окна.

```bash
godot --headless --path . -s res://tests/test_camera.gd
```

### `test_damage_calculator.gd`

Проверяет базовый урон, порядок модификаторов, типы урона, ограничения отрицательных значений и защиты, повторное использование `DamageResult`.

```bash
godot --headless --path . -s res://tests/test_damage_calculator.gd
```

### `benchmark_damage_calculator.gd`

Синтетический бенчмарк полного конвейера урона: прогрев, несколько серий, медианная скорость и время одного вызова. Запрос и результат переиспользуются, как предполагает горячий путь. Это замер без столкновений, модификаторов сущностей, сети и отображения, а не FPS игры.

```bash
godot --headless --path . -s res://tests/benchmark_damage_calculator.gd -- --iterations=1000000 --rounds=5
```

### `benchmark_modifiers.gd`

Синтетический бенчмарк конвейера модификаторов: полная пересборка статов, кэшированный `get_stats`, заполнение запроса и расчёт, условные модификаторы на попадании через `DamageSystem.deal`. Контрольные значения проверяются после каждой серии, так что бенчмарк одновременно сторожит математику.

```bash
godot --headless --path . -s res://tests/benchmark_modifiers.gd -- --iterations=100000 --rounds=5
```

### `test_biome_import.gd`

Проверка импортёра.

- **`BlobScanner` на всех темах:** каждый лист земли, дорог и обрывов из `data/themes` сканируется заново, и все 47 форм должны совпасть с тем, что рисует тема.
- **Фикстура `tests/fixtures/pine_import`** собирает хвойный лес из листов Sprout Lands. Раскладки листов, прямоугольники, размер, блокировка, размещение и коллизии пропсов сравниваются с ручными `pine.tres` и `data/props`.
- **Генерация:** 10 данжей с импортированным биомом.
- **Сохранение:** биом пишется в `user://import_test` и загружается обратно.

```bash
godot --headless --path . -s res://tests/test_biome_import.gd
```

### `test_room_navigation.gd`

Проверяет навмеш через настоящий `NavigationServer2D` на сгенерированных комнатах:

- центр достигает каждой двери по навигационному пути, как и по сетке;
- через обрыв путь на навмеше есть ровно тогда, когда его находит `RoomMap.find_path`/`can_step`;
- каждый блок лестницы соединяет верхнюю и нижнюю клетку на навмеше;
- каждый навигационный путь проверяется выборкой по маршруту: все клетки проходимы, все пересечённые рёбра удовлетворяют `can_step` (с учётом легальных проходов ровно по вершине сетки).

```bash
godot --headless --path . -s res://tests/test_room_navigation.gd -- --seeds=3
```

Без `--fixed-fps`: с ним навигационный сервер не успевает синхронизировать регионы, и меши оказываются пустыми. Тест ждёт итераций сервера через `map_force_update`.

### `test_basic_enemy.gd`

Поведенческие проверки `BasicEnemy` с инжектированным `DamageSystem` против боевого состояния заглушки-героя на ровной комнате:

- вне `detection_range` стоит в `IDLE`;
- внутри догоняет (`CHASE`) и сокращает дистанцию;
- `TELEGRAPH` неподвижен и без урона весь замах;
- после `telegraph_duration` ровно один удар с значениями из `data/enemies/basic_enemy.tres` (урон HP, poise, тип `PHYSICAL`);
- между ударами выдерживается `attack_cooldown`;
- герой без `combatant_state` и враг без `damage_system` не роняют тест (удар — no-op);
- отбрасывание: снос на полную дистанцию за 0,12 с, скольжение сквозь стан, упор в стену (кламп у стены, а не проход сквозь неё).
- два врага с общим ресурсом имеют независимые runtime-компоненты и сброс при входе в комнату;
- обработчик урона видит `TELEGRAPH` до начала cooldown; промах до `deal()` не очищает предыдущий результат.

```bash
godot --headless --fixed-fps 60 --path . -s res://tests/test_basic_enemy.gd
```

`--fixed-fps` гоняет физику без ожидания реального времени — тайминги состояний считаются кадрами.

### `test_enemy_brain.gd`

Чистые проверки `EnemyBrain`: границы дистанций, точный такт удара и перехода в cooldown, восстановление после промаха, пауза, сброс и независимость экземпляров. Игровые узлы и физические кадры не нужны.

```bash
godot --headless --path . -s res://tests/test_enemy_brain.gd
```

### `test_enemy_tick_order.gd` и `test_enemy_simulation.gd`

Регрессия чтения актуального proxy на том же такте и контракты фазовой комнаты R2: снимок, единичные тики/движение, подготовка смертей, актуальные попадания и границы epoch. Проверка порядка использует прежние API и воспроизводит ошибку на базе до R2.

```bash
godot --headless --fixed-fps 60 --path . -s res://tests/test_enemy_tick_order.gd
godot --headless --fixed-fps 60 --path . -s res://tests/test_enemy_simulation.gd
```

### `test_defense_formula.gd`

Проверяет `DefenseFormula`: ноль, положительная и отрицательная защита, пределы диапазона 0–2, монотонность, вырожденная константа и интеграцию с калькулятором урона.

```bash
godot --headless --path . -s res://tests/test_defense_formula.gd
```

### `test_modifiers.gd`

Проверяет `ModifierSet` и `ModifierDefinition`: ленивую пересборку статов, стаки и потолок, повторное наложение без стаков, истечение длительности, стабильный порядок, условия по статусу цели и порогу HP, смешанные операции без двойного применения, хук `after_damage`, изоляцию владельцев.

```bash
godot --headless --path . -s res://tests/test_modifiers.gd
```

### `test_damage_system.gd`

Проверяет `DamageSystem`: прямые попадания и фактический урон, смерть, отклонение мёртвых/неуязвимых/союзных целей, истечение i-frames, poise-стаггер, реген poise, хитстоп, наложение статусов атакой, уведомления `after_damage`, усиление от кровотечения, убийства DoT и атрибуцию источника, отбрасывание (полная дистанция за 0,12 с, отказ для DoT/i-frames/добивающего удара и при нулевой дистанции или направлении).

```bash
godot --headless --path . -s res://tests/test_damage_system.gd
```

### `test_statuses.gd`

Проверяет `StatusSet` по значениям GDD: стаки, потолки и обновление длительности, каденцию и объединение DoT, типы урона DoT (горение — магический, яд — физический), полную длительность тиков, охлаждение и заморозку на 10 стаках, обновление стана, параметры кровотечения.

```bash
godot --headless --path . -s res://tests/test_statuses.gd
```

### `test_hit_registry.gd`

Проверяет правила повторных попаданий `HitRegistry`: one-shot атаки, лимиты попаданий, кулдауны в боевых тактах, неограниченные попадания, изоляцию по экземплярам атаки и целям, защиту от двойного попадания в один такт, очистку.

```bash
godot --headless --path . -s res://tests/test_hit_registry.gd
```

### `test_hitboxes.gd`

Интеграционные проверки доставки урона на настоящих пересечениях `Area2D`: хитбокс → хёртбокс, фильтр фракций и самопопаданий, проверки i-frames и смерти через `DamageSystem`, правила повторов `HitRegistry` на физических тактах, блокировку повторного входа, очистку регистра при `end_attack()`/освобождении узла, мгновенный AoE shape-запросами.

```bash
godot --headless --fixed-fps 60 --path . -s res://tests/test_hitboxes.gd
```

### `test_handshake_codec.gd`

Проверяет round-trip всех сообщений handshake и отказ на пустой, обрезанный, oversized-пакет, неверный magic, неизвестный тип, лишние байты и невалидные строки.

```bash
godot --headless --path . -s res://tests/test_handshake_codec.gd
```

### `test_loopback_transport.gd`

Проверяет отложенные connect/disconnect-события, доставку байтов в обе стороны только после `poll()`, копирование исходного буфера, адресацию, отказ неизвестному peer и запрет отправки после `close()`.

```bash
godot --headless --path . -s res://tests/test_loopback_transport.gd
```

### `test_hero_combat.gd`

Фиксотактовые проверки `HeroCombatState` + `HeroActionController` на значениях `data/heroes/hero_default.tres`: ручная атака (20 физического, перезарядка 0,35 с, автоатаки нет), движение и facing, каст скилла (40 магического, кулдаун 3 с), рывок (3 м / 0,18 с, i-frames, кулдаун 0,8 с), рывок по facing без ввода, dash-cancel перезарядки атаки, смерть, регистрацию действий `HeroInput`, отбрасывание (перекрывает движение по намерению, i-frames рывка блокируют толчок, снос складывается с бегущим рывком, карманного героя тоже сносит).

```bash
godot --headless --path . -s res://tests/test_hero_combat.gd
```

### `test_party_controller.gd`

Проверяет `PartyController` на `data/heroes/party_default.tres`: ровно 3 героя, тикание карманных кулдаунов при неизменном HP, кулдаун свапа 1 с, запрет свапа на мёртвого, обход next/prev с пропуском мёртвых, свап во время рывка (рывок и i-frames продолжаются в кармане), отмену незаконченного скилла без траты кулдауна, отказ рывка во время скилла.

```bash
godot --headless --path . -s res://tests/test_party_controller.gd
```

### `test_remote_hero_view.gd`

Проверяет применение снапшота к `RemoteHeroView`, перевод метров в пиксели, скрытие неактивного героя и отсутствие физического тела, коллизий, хёртбокса и обратной записи в контроллер/HP.

```bash
godot --headless --path . -s res://tests/test_remote_hero_view.gd
```

### `test_combat_preview.gd`

Интеграционный тест играбельного превью-боя: инстанцирует настоящую `dungeon_preview.tscn` и гоняет её физику.

- зарегистрированы все действия `HeroInput`;
- отряд из 3 героев и враги комнаты на общем `DamageSystem`/`StatusConfig`; враги следят за `HeroProxy`, навмеш построен;
- движение через `Input.action_press` согласовано с видом (`CombatHeroView`);
- ручная атака через транзитный `Hitbox2D` + `HitRegistry` + хёртбокс врага снимает ровно 20 HP, телеграф врага не наносит урон раньше времени;
- скилл (40 магического, кулдаун стартует после выстрела) и рывок (3 м, кулдаун бежит);
- отбрасывание интеграционно: удар героя сдвигает врага ровно на дистанцию из данных по направлению хитбокс → хёртбокс, толчок в стену упирается в неё (кламп у «стена − радиус», без прохода сквозь), удар врага несёт свою дистанцию отбрасывания;
- свап и карманные кулдауны, автосвап после гибели активного героя от телеграфа врага;
- мёртвые враги исчезают; переход в соседнюю комнату пересобирает бой.

```bash
godot --headless --fixed-fps 60 --path . -s res://tests/test_combat_preview.gd
```

`--fixed-fps` гоняет физику без ожидания реального времени. Тест сдерживает фоновых врагов станом, чтобы они не мешали проверяемым.

---

## Инструменты (`tools/`)

### `import_biome.gd`

CLI к `BiomeImporter`: печатает отчёт и ошибки, затем записывает биом (код выхода 1 при ошибке).

```bash
godot --headless --path . -s res://tools/import_biome.gd -- res://tiles/biomes/<id> [--dry-run] [--out=res://data]
```

### `recolor_hills.py`

Python-скрипт (нужен Pillow). Перекрашивает `Hills.png` базового пака под палитры других листов земли:
- `tiles/generated/hills_spring.png` — под траву Sorry pack;
- `tiles/generated/hills_snow.png` — под снег.

Склоны и лестницы сохраняют цвет. Новая палитра добавляется словарём в `PALETTES`.

```bash
python3 tools/recolor_hills.py
```
