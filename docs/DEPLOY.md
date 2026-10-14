# Деплой PortalLab на Monad Testnet

## Случайность

Игра использует **Pyth Entropy V2** через отдельный контракт
`PythEntropySource` (адреса Pyth зашиты в `script/Deploy.s.sol`, SPEC §6.1).
Деплой — два контракта: сначала `PythEntropySource`, затем `PortalLab` с его
адресом. **Только тестнет Monad**, в mainnet не деплоим.

---

## Предварительные условия

- Foundry (Windows: `.tools\foundry-win\forge.exe` и `cast.exe`, Linux: `.tools/foundry/forge` и `cast`)
- Тестовые монеты Monad: [faucet.monad.xyz](https://faucet.monad.xyz)
- Деплой стоил 1,285 MON (13 октября 2026); оценка `forge` покажет примерно
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
деплое спрашивается только пароль.

**Windows (из папки `contracts/`):**
```powershell
..\..\.tools\foundry-win\cast.exe wallet import portal-deployer --interactive
```

**Linux (из папки `contracts/`):**
```bash
../../.tools/foundry/cast wallet import portal-deployer --interactive
```

`portal-deployer` — псевдоним хранилища; деплой идёт через
`--account portal-deployer`.

---

## Команды

### Шаг 0: Проверить баланс

Нужно не менее 1,5 MON с запасом.

```powershell
..\..\.tools\foundry-win\cast.exe balance <адрес> --rpc-url monad_testnet --ether
```

### Шаг 1: Примерка (обязательно перед отправкой)

Проверяет доступность RPC, прохождение конструктора и даёт оценку газа —
**ничего не тратя**.

```powershell
..\..\.tools\foundry-win\forge.exe script script/Deploy.s.sol --rpc-url monad_testnet
```

### Шаг 2: Деплой

```powershell
..\..\.tools\foundry-win\forge.exe script script/Deploy.s.sol --rpc-url monad_testnet --broadcast --account portal-deployer
```

Linux: то же с `../../.tools/foundry/forge`.

> **Заметка о флаге `--interactive`.** В Foundry 1.8.3 `-i` / `--interactive`
> (без значения) читает один ключ интерактивно, а `--interactives <ЧИСЛО>` —
> другой флаг. Запись `--interactive 1` форж принимает за аргумент скрипта и
> падает с «encode length mismatch: expected 0 types, got 1». Используйте
> `--account <имя>` через хранилище.

### Шаг 3: Верификация (Sourcify на MonadVision)

Команды, которые сработали 14 октября 2026. Сначала верифицировать **малый**
контракт.

Параметры верификатора: `--verifier sourcify --verifier-url
https://sourcify-api-monad.blockvision.org/`.

**`PythEntropySource`** — аргументы конструктора:
```powershell
..\..\.tools\foundry-win\cast.exe abi-encode "constructor(address,address)" <entropy> <provider>
```
где `<entropy>` и `<provider>` — адреса из `script/Deploy.s.sol`
(`PYTH_ENTROPY`, `PYTH_PROVIDER`).

**`PortalLab`** — аргументы конструктора равны входу деплой-транзакции за
вычетом скомпилированного initcode. Из папки `contracts/`:

```powershell
$run = Get-Content broadcast\Deploy.s.sol\10143\run-latest.json -Raw | ConvertFrom-Json
$tx  = ($run.transactions | Where-Object contractName -eq 'PortalLab').transaction
$code = (Get-Content out\PortalLab.sol\PortalLab.json -Raw | ConvertFrom-Json).bytecode.object
if (-not $tx.input.ToLower().StartsWith($code.ToLower())) { throw "initcode mismatch - STOP" }
$labArgs = "0x" + $tx.input.Substring($code.Length)
```

Затем `forge verify-contract <адрес> <контракт> --chain 10143 --verifier
sourcify --verifier-url https://sourcify-api-monad.blockvision.org/
--constructor-args <аргументы>`.

Результат — статус `match` (совпадение рантайм-байткода); `exact match`
недостижим при `bytecode_hash = "none"`. Запасной вариант — Monadscan
(`--verifier etherscan`, нужен API-ключ).

---

## После деплоя

1. Записать адреса в `app/src/config.ts` и в адреса README.
2. Обновить `app/src/PortalLab.abi.json`, если менялся ABI.
3. Записать деплой в `docs/STATUS.md` (адреса, дата, стоимость).

### Адрес контракта

Скрипт печатает его в stdout: `PortalLab deployed at: 0x...`. Если вывод
потерялся, адрес лежит в
`contracts/broadcast/Deploy.s.sol/10143/run-latest.json`.

### Конфигурация

```powershell
..\..\.tools\foundry-win\cast.exe call <адрес> "config()" --rpc-url monad_testnet
```

Значения читаются из `contracts/src/GameConfig.sol`; на момент написания:
- `hpStart = 50`, `hpMax = 100`
- `secPerHour = 15`
- `epochHours = 36`
- `requestTimeoutHours = 1`
- `outsiderTimeoutHours = 40`

(`maxSpawnsPerTx` и `deafNarrowThreshold` удалены из конфигурации.)

### Ручная проверка на цепочке

**Не проверено на тестнете.**

`startGame` и `act` — `payable`: к ним прикладывается плата Pyth, неиспользованное
возвращается. Сначала прочитать плату:

```powershell
..\..\.tools\foundry-win\cast.exe call <PythEntropySource> "fee()(uint256)" --rpc-url monad_testnet
```

```powershell
# Начать партию (платит за первое слово)
..\..\.tools\foundry-win\cast.exe send <адрес> "startGame()" --value <плата> --rpc-url monad_testnet --account portal-deployer

# Продвинуть мир (бесплатно, открыт любому)
..\..\.tools\foundry-win\cast.exe send <адрес> "sync(address)" <адрес_игрока> --rpc-url monad_testnet --account portal-deployer

# Совершить действие: слот (0–11) и код действия (таблица ниже)
..\..\.tools\foundry-win\cast.exe send <адрес> "act(uint8,uint8)" <слот> <код> --value <плата> --rpc-url monad_testnet --account portal-deployer
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

---

## Газ (локальный benchmark, Веха 3 — история)

Результаты `forge test --gas-report` на контракте `PortalLab`, 2026-09-30.
**Это история Вехи 3**: контракт с тех пор изменился (Pyth, эпохи, рождения по
часам созревания), цифры не актуальны.

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
§14.2.2. Худший случай газа раскрытия на пересечении эпохи — 588 850 (STATUS.md).
