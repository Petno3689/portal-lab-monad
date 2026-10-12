# Деплой PortalLab на Monad Testnet

## Важно: предсказуемая случайность

Эта версия использует `RandomStub` — детерминированный генератор (`keccak(address, counter)`).
Любой желающий может вычислить заранее, какие порталы появятся и каким будет
результат разведки. **Деплой только в тестнет, только для проверки механики.**
Настоящая энтропия через Pyth Entropy запланирована на Веху 4.

---

## Предварительные условия

- Foundry (Windows: `.tools\foundry-win\forge.exe` и `cast.exe`, Linux: `.tools/foundry/forge` и `cast`)
- Тестовые монеты Monad: [faucet.monad.xyz](https://faucet.monad.xyz)
- Деплой стоит около **0,6 MON** по факту; оценка `forge` покажет примерно
  вдвое больше, потому что считает по максимальной цене газа.

**Ключ НИКОГДА не попадает в репозиторий и НИКОГДА не передаётся ревьюеру.
Деплой выполняет только владелец ключа.**

> **Все команды запускаются из папки `contracts/`.** Именно там лежит
> `foundry.toml`, без которого `forge` не знает про `monad_testnet`. Оттуда
> до бинарников ровно два уровня вверх: `..\..\.tools\` (Windows) /
> `../../.tools/` (Linux).

---

## Настройка хранилища ключа (один раз)

Ключ шифруется и хранится в `~/.foundry/keystores` — вне проекта. При каждом
деплое спрашивается только пароль; сам ключ в терминал больше не вводится.

**Windows (из папки `contracts/`):**
```powershell
..\..\.tools\foundry-win\cast.exe wallet import deployer --interactive
```

**Linux (из папки `contracts/`):**
```bash
../../.tools/foundry/cast wallet import deployer --interactive
```

`deployer` — псевдоним; можно взять любой. После этого деплой идёт через
`--account deployer` (см. Шаг 2).

---

## Команда деплоя

### Шаг 0: Проверить баланс

Нужно не менее 0,7 MON с небольшим запасом.

**Windows:**
```powershell
..\..\.tools\foundry-win\cast.exe balance <адрес> --rpc-url monad_testnet --ether
```

**Linux:**
```bash
../../.tools/foundry/cast balance <адрес> --rpc-url monad_testnet --ether
```

### Шаг 1: Примерка (обязательно перед отправкой)

Проверяет доступность RPC, прохождение конструктора и даёт оценку газа —
**ничего не тратя**.

**Windows (PowerShell):**
```powershell
..\..\.tools\foundry-win\forge.exe script script/Deploy.s.sol --rpc-url monad_testnet
```

**Linux:**
```bash
../../.tools/foundry/forge script script/Deploy.s.sol --rpc-url monad_testnet
```

### Шаг 2: Деплой

Использует зашифрованное хранилище (см. «Настройка хранилища» выше). Форж
спросит пароль от ключа.

**Windows (PowerShell):**
```powershell
..\..\.tools\foundry-win\forge.exe script script/Deploy.s.sol --rpc-url monad_testnet --broadcast --account deployer
```

**Linux:**
```bash
../../.tools/foundry/forge script script/Deploy.s.sol --rpc-url monad_testnet --broadcast --account deployer
```

> **Заметка о флаге `--interactive`.** В Foundry 1.8.3 есть два разных флага:
> `-i` / `--interactive` (без значения) читает один ключ интерактивно, и
> `--interactives <ЧИСЛО>` (со значением) — другой флаг. Запись `--interactive 1`
> с числом передаёт `1` не туда: форж принимает её за аргумент скрипта и
> падает с «encode length mismatch: expected 0 types, got 1». Использовать
> `--account <имя>` через хранилище — надёжнее.

### Шаг 3: Верификация на эксплорере

**Текущий статус: не выполнена, перенесена в Веху 4** (подробности в
`docs/SPEC.md`, §14.2.8).

Два способа пробовали 30 сентября 2026:

- `forge verify-contract` с верификатором `sourcify` — отваливается по таймауту;
  один ответ вернул код 429 (сервис перегружен). Посылка тяжёлая:
  `use_literal_content = true` вшивает все исходники в метаданные.
- Форма эксплорера (Standard JSON input) — крутилась больше семи минут и не
  завершилась. Вероятная причина та же плюс `via_ir`, который делает
  пересборку медленной.

При этом **настройки компиляции проверены и верны**: в сгенерированном
standard-json лежат компилятор `0.8.28+commit.7893614a`, оптимизатор 200
прогонов, `evmVersion cancun`, `viaIR`, `bytecodeHash none`, `appendCBOR`.
Когда верификация будет доступна, настройки уже правильные.

---

## Что проверить после деплоя

### Адрес контракта

Скрипт печатает его в stdout: `PortalLab deployed at: 0x...`
Если вывод потерялся, адрес сохранён в
`contracts/broadcast/Deploy.s.sol/10143/run-latest.json`.

### Конфигурация

```powershell
..\..\.tools\foundry-win\cast.exe call <адрес> "config()" --rpc-url monad_testnet
```

Значения, которые должны прийти (читать ABI-декодером или через эксплорер):
- `hpStart = 50`
- `hpMax = 100`
- `secPerHour = 15`
- `maxSpawnsPerTx = 3`

### Ручная проверка на цепочке

```powershell
# Начать партию
..\..\.tools\foundry-win\cast.exe send <адрес> "startGame()" --rpc-url monad_testnet --account deployer

# Продвинуть мир (принимает любой вызывающий)
..\..\.tools\foundry-win\cast.exe send <адрес> "sync(address)" <адрес_игрока> --rpc-url monad_testnet --account deployer

# Совершить действие: слот (0–11) и код действия (таблица ниже)
..\..\.tools\foundry-win\cast.exe send <адрес> "act(uint8,uint8)" <слот> <код> --rpc-url monad_testnet --account deployer
```

### Коды действий (`Action`)

| Код | Идентификатор | Суть |
|-----|---------------|------|
| 0 | `ToggleQuestioned` | пометить вопросом |
| 1 | `Stabilize` | стабилизировать |
| 2 | `Destabilize` | дестабилизировать |
| 3 | `SendObserver` | послать наблюдателя |
| 4 | `RecallObserver` | отозвать наблюдателя |
| 5 | `SendRescuer` | послать спасателя |
| 6 | `RecallRescuer` | отозвать спасателя |
| 7 | `Evacuate` | эвакуировать существ |
| 8 | `Close` | закрыть портал |

### Предупреждения в логе деплоя

Убедиться, что в логе есть строки-предупреждения про `RandomStub`.

---

## Газ (локальный benchmark, Веха 3.1)

Результаты `forge test --gas-report` на контракте `PortalLab`, 2026-09-30:

| Функция      | min    | avg     | median  | max     |
|:-------------|-------:|--------:|--------:|--------:|
| `startGame`  | 64 507 | 75 626  | 80 142  | 80 142  |
| `act`        |174 873 | 180 742 | 179 467 | 190 914 |
| `sync`       |137 043 | 174 359 | 169 409 | 235 784 |
| `preview`    |138 682 | 147 142 | 147 142 | 155 602 |
| `getGame`    |  6 269 |   6 269 |   6 269 |   6 269 |
| `getPortals` | 54 661 |  54 661 |  54 661 |  54 661 |
| `config`     |  9 350 |   9 350 |   9 350 |   9 350 |

Все значения в единицах газа EVM. Фактический расход на сети — в `docs/SPEC.md`,
§14.2.2.

Для справки: в Вехе 0 на игрушечном контракте `tick()` стоил 34 728 газа.
