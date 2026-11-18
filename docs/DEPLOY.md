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
- Деплой стоил 1,285 MON (13 октября 2026), 1,334 MON (28 октября 2026) и 1,492 MON (18 ноября 2026, при 115 gwei); оценка `forge` покажет примерно
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

> **Команды запускаются из `contracts/`; путь к инструментам задавать
> абсолютным.** При запуске из корня репозитория относительные пути
> `..\..\.tools\...` не срабатывали. Надёжнее один раз задать:
> ```powershell
> $F = "C:\Users\1\Desktop\LNP-Monad\.tools\foundry-win"
> ```
> и вызывать `& "$F\forge.exe"`, `& "$F\cast.exe"` вместо относительных путей
> ниже.

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
контракт. Сервер Sourcify у BlockVision временами лежал (28 октября 2026), позже
восстановился. Sourcify может переиспользовать прежнюю проверенную компиляцию,
если байткод тот же (так было с адаптером 18 ноября 2026). Результат проверять запросом
`GET /v2/contract/10143/<адрес>` — ожидается `"match"`. Эндпоинт
`/check-by-addresses` ненадёжен: он отвечает `false` даже для верифицированных
контрактов. Запасной вариант — Monadscan.

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

## NameRegistry

Отдельный контракт ников лидерборда (SPEC §15.9), без аргументов конструктора.
Деплоится независимо от `PortalLab`. Из папки `contracts/`, `$F` — как в начале
раздела «Команды».

Примерка (без `--broadcast`, ничего не тратит):

```powershell
& "$F\forge.exe" script script/DeployNames.s.sol --rpc-url monad_testnet
```

Деплой:

```powershell
& "$F\forge.exe" script script/DeployNames.s.sol --rpc-url monad_testnet --broadcast --account portal-deployer
```

Верификация (аргументов конструктора нет):

```powershell
& "$F\forge.exe" verify-contract <адрес> src/NameRegistry.sol:NameRegistry --chain 10143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/
```

Затем записать адрес в `NAME_REGISTRY_ADDRESS` в `app/src/config.ts`. Новый
реестр начинает без имён: ники прежнего реестра в нём не появятся.

Текущий реестр: `0xe14b1389853aD407A5B72193Ae3Bd1bb35602525`, развёрнут
2 ноября 2026 (блок 76339056, tx
`0x757943f94794341d692c5083205d36ba75cd0a9fef2971af8598f55abfdef795`,
805 138 газа, 0,08454 MON при 105 gwei), Sourcify `match`.

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

Ожидаемые значения — в `contracts/src/GameConfig.sol` того коммита, с которого
идёт деплой. При расхождении прав `GameConfig.sol`, а этот список надо поправить.
Финальная версия (`31abc75`, 18 ноября 2026):
- `hpStart = 80`, `hpMax = 100`, `hpCollapsePerDeath = 8`
- `pressureRampPerHour = 2`
- `secPerHour = 15`
- `epochHours = 36`
- `requestTimeoutHours = 8`
- `outsiderTimeoutHours = 40`

(`maxSpawnsPerTx` и `deafNarrowThreshold` удалены из конфигурации.)

### Ручная проверка на цепочке

**Сами команды `cast` ниже на тестнете не прогонялись**; поведение контракта
проверено через фронт.

`startGame` и `act` — `payable`: к ним прикладывается плата Pyth, неиспользованное
возвращается (измерено 1 ноября 2026). Сначала прочитать плату:

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

## Заметки по сборке

- Официальный шаблон Foundry от Monad содержит несуществующие ключи `metadata` и
  `metadata_hash`; Foundry молча их игнорирует, и `bytecode_hash` остаётся `ipfs`.
  Правильно (как в `contracts/foundry.toml`): `bytecode_hash = "none"`,
  `cbor_metadata = true`.
- Remix 2.6.0 падает после деплоя на Monad (`Cannot read properties of undefined
  (reading 'result')`), хотя транзакция в сети проходит; адрес берётся из
  эксплорера. Remix также сериализует транзакции.
