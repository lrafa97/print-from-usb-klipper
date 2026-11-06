# CLAUDE.md — print-from-usb-klipper

## Repositório público: regra obrigatória

Este repositório é público, incluindo este ficheiro, os commits e o histórico. Vale para qualquer sessão do Claude, na web ou no PC.

- Nunca publicar nomes de pessoas, nomes reais de máquinas, IPs reais, endereços MAC, números de série, nomes de redes Wi-Fi, caminhos de pastas pessoais, emails, tokens, palavras-passe, nomes de clientes, projetos de trabalho ou notas sobre o utilizador.
- Usar sempre exemplos genéricos: `printer`, `192.168.1.50`, `<MAC>`, "máquina de teste".
- Antes de cada commit, rever o conteúdo a publicar. Se tiver dados destes, substituí-los antes do push.

Instruções para o Claude (e para quem pegar neste projeto). Versão do pacote à data de escrita: **1.1.4** (ficheiro `VERSION`).

## 1. Objetivo

Fazer com que uma impressora Klipper se comporte como uma impressora comercial com porta USB: o utilizador espeta **qualquer pen em qualquer porta**, navega na pen no Mainsail ou no KlipperScreen, toca num ficheiro, e **só esse ficheiro** é copiado para a memória interna e impresso a partir da cópia local. A pen pode ser retirada assim que a impressão arranca. Os ficheiros copiados acumulam-se e nunca são apagados automaticamente.

- **Para quem:** quem constrói impressoras Klipper para clientes e qualquer pessoa com Klipper + Moonraker. O cliente final não pode ter de correr scripts nem configurar nada ao inserir uma pen.
- **Porquê:** até aqui só se imprimia com ficheiros enviados pela interface web. Copiar a pen inteira (p. ex. 32 GB de gcodes) estava fora de questão, por isso a escolha é sempre do utilizador, ficheiro a ficheiro.
- **Instalação:** uma única linha colada por SSH (estilo KIAUH); atualizável pelo Update Manager do Mainsail.

## 2. Ambiente

- **Máquina alvo:** Raspberry Pi onde ligam as placas da impressora (o Pi é o que importa aqui). Debian/Raspberry Pi OS com systemd.
- **Modelos de Pi onde já correu (confirmado pelo autor):** Raspberry Pi 5, Pi 3B+ e Pi 3B, todos com funcionamento normal. Mainsail + KlipperScreen, pens FAT32.
- **Sistemas testados:** Debian 11 (Python 3.9) e Debian 13 (Python 3.13).
- **Dependências externas:** Klipper, Moonraker (componente Python carregado dentro do Moonraker), Mainsail, KlipperScreen, disposição KIAUH por omissão (`~/printer_data`, `~/moonraker`), udev, systemd, `util-linux` (`findmnt`, `flock`), `blkid`, `logger`, `curl` (opcional, para saber se há impressão em curso). Kernel com exFAT e NTFS (`ntfs3`).
- **Projetos próprios relacionados** (independentes, não partilham código): Klipper-IP-Status (macro `SHOW_IP_ADDRESS`) e klipper-hotspot.
- **Desenvolvimento:** clone local em Windows; testes locais em Ubuntu (WSL).
- **Licença:** GPL-3.0 (Klipper e Moonraker são GPL-3.0 e o componente corre dentro do Moonraker). KlipperScreen julga-se AGPL-3.0, **por verificar** antes de qualquer fork.

## 3. Arquitetura

Raiz do repositório:

| Caminho | Papel |
|---|---|
| `install.sh` | Instalador idempotente. Eleva-se com sudo; valida pré-requisitos; recusa se já existir outra macro `SDCARD_PRINT_FILE`; remove `usbmount`; instala o script de mount em `/usr/local/lib/usb-gcode/`, `/etc/usb-gcode.conf`, o serviço systemd e a regra udev; cria `gcodes/USB` e `gcodes/Imported`; liga o componente por symlink; reescreve o bloco marcado `usb-gcode` no `moonraker.conf`; copia a macro e põe o `[include]` no topo do `printer.cfg`; reinicia (só Moonraker nas atualizações; Moonraker + Klipper na primeira instalação). Salta reinícios durante uma impressão. |
| `uninstall.sh` | Remove tudo o que o instalador pôs e reinicia Klipper e Moonraker. Recusa durante uma impressão (`--force` ultrapassa). Mantém `gcodes/Imported`, backups e o clone. |
| `doctor.sh` | Relatório de saúde **só de leitura**: instalação, serviços, watchdog, conflitos (usbmount/autofs/udisks2/fstab/outra macro), pens, versões, log de mount recente. É o que se pede ao utilizador que cole ao pedir ajuda. |
| `src/usb-gcode.sh` | Script root de mount/umount (flock, só read-only, vfat/exfat/ntfs3/ext4). Instalado como cópia root em `/usr/local/lib/usb-gcode/`. |
| `src/usb_import.py` | Componente Moonraker `usb_import`: recebe o pedido de impressão, copia em *thread*, verifica, move atomicamente e arranca a impressão; vigia o estado do mount para atualizar a pasta no Mainsail; watchdog do KlipperScreen; aviso de *drift*. Instalado como **symlink** para o clone. |
| `src/usb_import.cfg` | Macro Klipper que redefine `SDCARD_PRINT_FILE` com `rename_existing`. |
| `tests/test_usb_import.py` | 23 testes `unittest` com um Moonraker simulado. |
| `VERSION` | Versão do pacote; o componente regista no log qual a versão que carregou e de onde. |
| `LICENSE`, `.gitattributes`, `.gitignore` | GPL-3.0; LF forçado em `sh/py/cfg/md/VERSION/LICENSE`; ignora `__pycache__`. |
| `README.md` | Documentação pública, **em inglês**. |

Fluxo de uma impressão:
1. udev deteta a partição USB → `usb-gcode@<dev>.service` (ligado ao dispositivo com `BindsTo`) monta em `~/printer_data/gcodes/USB`, só leitura. Ao retirar a pen o serviço pára e desmonta.
2. Mainsail/KlipperScreen chamam `SDCARD_PRINT_FILE FILENAME=USB/...`. A macro entrega os caminhos `USB/` ao Moonraker via `action_call_remote_method("usb_import_print", ...)`; o resto vai para o comando original (`_USB_IMPORT_SDCARD_PRINT_FILE`).
3. O componente copia para `~/printer_data/.usb_import_tmp/.nome.part` (fora da árvore vigiada, mesmo sistema de ficheiros), `fsync`, confirma o tamanho, `os.replace` para `gcodes/Imported`, e só então inicia a impressão a partir da cópia. Mensagens de progresso por `RESPOND`.

Regras do componente: extensões `.gcode .gco .g`; verificação de *path traversal*; ficheiro idêntico (sha256) não duplica; mesmo nome com conteúdo diferente ganha sufixo `_1`; verifica espaço livre (margem 64 MB); só uma cópia de cada vez.

## 4. Instalar, atualizar e testar

**Instalar** (numa máquina nova; é só isto):

```
(command -v git >/dev/null || (sudo apt-get update && sudo apt-get install -y git)) && cd ~ && git clone https://github.com/lrafa97/print-from-usb-klipper.git && ./print-from-usb-klipper/install.sh
```

Layout diferente: `PRINTER_DATA=/caminho MOONRAKER_DIR=/caminho ./print-from-usb-klipper/install.sh`. Outras variáveis: `TARGET_USER`, `SCREEN_SERVICE` (vazio desativa o watchdog), `--no-restart`.

**Atualizar:**
- Mainsail: Machine → Update Manager → atualizar *print-from-usb-klipper*. Substitui o código do componente (symlink) e reinicia só o Moonraker. Se o Mainsail mostrar o aviso "usb-gcode: ... differ from the repository", correr: `cd ~/print-from-usb-klipper && ./install.sh`
- Manual: `cd ~/print-from-usb-klipper && git pull && ./install.sh`
- Se a macro mudou, reiniciar o Klipper quando a impressora estiver parada.

**Desinstalar:** `~/print-from-usb-klipper/uninstall.sh` (antes de apagar a pasta clonada).

**Diagnóstico:** `./doctor.sh`; depois `journalctl -t usb-gcode -n 30`, `findmnt ~/printer_data/gcodes/USB`, `tail -n 50 ~/printer_data/logs/moonraker.log`. Usar `grep -a` no `moonraker.log` (pode ter bytes NUL).

**Testes sem hardware** (correm em qualquer máquina com Python 3, sem Moonraker nem Klipper):

```
python3 -m unittest discover -s tests -v
```

Estado à data: 23 testes, todos passam. Cobrem cópia, verificações de caminho, pedido de impressão, watchdog do ecrã e aviso de *drift*.

**O que só se valida com hardware real** (os testes não cobrem):
- udev + systemd + mount real com pens diferentes e portas diferentes; retirar a pen e ver o desmonte.
- Lista de ficheiros no Mainsail e no KlipperScreen ao inserir/retirar a pen.
- Copiar e imprimir um ficheiro; retirar a pen depois da mensagem de cópia concluída e confirmar que a impressão continua.
- Impressão normal de um ficheiro enviado pela web (a macro tem de o deixar passar intacto).
- Fluxo de atualização pelo Update Manager e o aviso de *drift*.
- Watchdog do KlipperScreen após reinício do Moonraker.
- Qualquer alteração à macro exige reiniciar o Klipper numa máquina real.

## 5. Decisões técnicas e porquê

- **Sobrepor `SDCARD_PRINT_FILE` com `rename_existing`.** É o comando que Mainsail e KlipperScreen usam para imprimir, por isso funciona nos dois sem alterar nenhum. Custo: se já existir outra macro com esse nome o Klipper não arranca; o instalador deteta e pára sem alterar nada.
- **Componente nativo do Moonraker (em vez de `gcode_shell_command`).** Assíncrono, acesso à API do Klipper e ao gestor de ficheiros, mensagens e avisos no Mainsail. Rejeitado `gcode_shell_command`: é uma extensão externa, bloqueia e não integra com os eventos de ficheiros.
- **Copiar só o ficheiro escolhido, no momento da impressão.** Rejeitado copiar tudo ao inserir (pen de 32 GB cheia), rejeitado imprimir direto da pen (retirá-la a meio estraga a impressão), rejeitado limpar a pasta de destino ao inserir (o utilizador quer que os ficheiros acumulem).
- **Mount read-only, `nosuid,nodev,noexec`, uid/gid do utilizador Klipper.** Não escreve na pen do cliente e não executa nada dela. `ext4` com `noload` para não reproduzir o journal.
- **udev + serviço systemd `BindsTo` o dispositivo**, em vez de entrada no `fstab` ou de automount: funciona em qualquer porta e com qualquer pen, e o desmonte acontece sozinho ao retirá-la. `fstab` por UUID/porta foi rejeitado por exigir configuração por pen.
- **Script de mount numa cópia root em `/usr/local/lib/usb-gcode/`.** O root nunca executa nada que o utilizador consiga editar. Por isso o script é cópia e não symlink.
- **Componente por symlink para o clone.** O Update Manager (`type: git_repo`, `managed_services: moonraker`) **não corre `install_script`**; com o symlink, atualizar o git já troca o código. O que é cópia (script de mount, regra udev, macro) é detetado por comparação e gera o aviso `usb_import_drift`.
- **Escrita atómica via ficheiro temporário fora da árvore vigiada.** Se o `.part` estivesse dentro de `gcodes`, o Moonraker/Mainsail veria ficheiros a meio.
- **Watcher do estado do mount (poll de 1 s) + eventos `delete_dir`/`create_dir`.** Montagens não geram inotify; é o que faz o Mainsail atualizar a pasta `USB` sozinho. O KlipperScreen só reage a eventos por ficheiro, por isso fica o botão de refresh (limitação aceite).
- **Reiniciar só o Moonraker nas atualizações.** Reiniciar também o Klipper deixava o KlipperScreen esgotar as tentativas de ligação.
- **Watchdog do KlipperScreen** (verifica 40 s depois de o Moonraker arrancar; reinicia o serviço no máximo 2 vezes; nunca arranca um serviço parado de propósito). Só atua se o serviço estiver em `moonraker.asvc`.
- **Purgar `usbmount` no instalador.** Conflito comprovado (ver secção 6). `udisks2`/`autofs`/`fstab` **não** são removidos (podem ser precisos para outra coisa); o `doctor.sh` aponta-os.
- **Backups numa pasta própria** (`config/print-from-usb-klipper-backup/`) com a primeira cópia original; migra os `*.bak-usbgcode` antigos.
- **GPL-3.0**, por o componente correr dentro do Moonraker.
- **Rejeitado/adiado: fork do KlipperScreen** para um botão "só copiar". Custos: manter o fork alinhado com o upstream, licença (AGPL por verificar) e atualizações deixarem de vir do Update Manager oficial. Alternativa mais leve a avaliar: entrada de menu no `KlipperScreen.conf` (não verificado se serve).

## 6. Não repetir

| O que falhou | Como se resolveu |
|---|---|
| Mount falhava com "already mounted or mount point busy". Causa: `usbmount` monta no *namespace* privado do udev. | Instalador faz `apt-get purge usbmount`; o script regista o erro real com uma dica; pedir reboot uma vez. |
| Pasta `USB` não atualizava no Mainsail. | O `.part` saiu da árvore vigiada; watcher do mount envia `delete_dir`+`create_dir`. A primeira tentativa com `root_update` **não** funcionou. |
| `install_script` do Update Manager não corria. | Symlink + `VERSION` + aviso de *drift* + `doctor.sh`. Não voltar a contar com `install_script`. |
| Depois de atualizar, o KlipperScreen ficava preso em "Connecting" (esgota ~4 tentativas, 4 s). | `managed_services: moonraker` apenas + watchdog. Manual: `sudo systemctl restart KlipperScreen`. |
| `doctor.sh` dava FAIL falso na versão. | `moonraker.log` tinha bytes NUL: usar `grep -a`. |
| `apt-get install git` dava 404 no Debian 11 (Bullseye em fim de vida). | A linha de instalação só instala git se faltar. |
| Ficheiros sem bit de execução (`doctor.sh: Permission denied`). | `git update-index --chmod=+x install.sh uninstall.sh doctor.sh src/usb-gcode.sh`. **Atenção:** os zips perdem o bit; confirmar sempre no repositório antes de publicar. |
| Apareceu um ficheiro `100755` no Pi. | Uma saída do git (`=>`) foi colada como comando. Dar sempre só comandos; avisar para nunca colar saídas. |
| `git add` fora do repositório, na pasta pessoal. | Correr git sempre dentro da pasta do repositório; apagou-se o `.git` perdido. |
| Re-extrair o zip por cima perdeu o `.git`. | Fluxo estável: clone local, `git pull --ff-only`, expandir o zip **por cima**, `git status`, `add`/`commit`/`push`. Não apagar a pasta do clone. |
| Teste de backup corrido com `sh` em vez de `bash`. | Os scripts são bash; testar sempre com `bash`. |
| Alterações à macro não surtiam efeito. | Macros só carregam com restart do Klipper; o instalador avisa quando a macro mudou. |
| Reboot a partir do KlipperScreen: "Interactive authentication required". | **Por resolver.** Não está relacionado com este pacote; foi apenas oferecida ajuda. |

## 7. Convenções

- **Idioma do pacote:** inglês — README, mensagens do instalador, mensagens do Moonraker/consola, comentários. O programa fica só em inglês para ser de uso público.
- **Idioma da conversa com o utilizador:** português europeu, direto e honesto. Dizer o que foi assumido e o que foi confirmado em máquina real; não afirmar que algo funciona sem ter sido testado.
- **Commits:** mensagem curta, no imperativo e em inglês, p. ex. `Keep config backups in their own folder`. Quando o Claude fizer o commit, acrescentar no fim as linhas de atribuição pedidas pela sessão (`Co-Authored-By` e `Claude-Session`). Subir `VERSION` em cada alteração publicada.
- **Como publicar:** a partir do clone no Windows, com o Claude Code, e só a pedido do utilizador.
- **Como trabalhar com ele:** instruções passo a passo, copiar-e-colar, uma coisa de cada vez; confirmar sempre `git status` antes do commit. Não começar trabalho adiado sem ele pedir. Estilo de engenheiro sénior: robusto, idempotente, reversível; o utilizador final nunca corre scripts ao inserir uma pen.
- **Regra de código:** não deixar o utilizador com a máquina pior do que estava. O `uninstall.sh` tem de repor Moonraker e Klipper como antes; o instalador não toca em nada se detetar conflito.
- **Antes de entregar:** correr os 23 testes e `bash -n` nos scripts; se mexer em `install.sh`, `uninstall.sh` ou na macro, dizer explicitamente que isso só fica provado numa máquina real.

## 8. Estado

**Feito e confirmado em máquina real** (Pi 5, Pi 3B+ e Pi 3B; Debian 11 e 13; Mainsail + KlipperScreen; pens FAT32):
- Instalação com `install.sh` e `doctor.sh` sem FAIL nas três máquinas, e uso normal confirmado nos três modelos de Pi.
- Mount em qualquer porta, leitura da pen no Mainsail e no KlipperScreen, cópia para `Imported` e impressão a partir da cópia.
- A pasta `USB` aparece/desaparece sozinha no Mainsail; no KlipperScreen precisa do botão de refresh (comportamento testado e aceite).
- Atualização pelo Update Manager do Mainsail (1.0.0 → 1.0.1) e o aviso de *drift*.
- Watchdog do KlipperScreen: confirmado uma vez num ecrã preso de verdade, que voltou a ligar.
- Conflito com `usbmount` identificado e tratado.
- Backups na pasta `print-from-usb-klipper-backup`.
- Licença GPL-3.0 e *Acknowledgements* no README (1.1.3).

**Só validado por código** (23 testes unitários com Moonraker simulado): lógica de cópia, duplicados e sufixo `_1`, espaço livre, *path traversal*, watchdog (limites e janela), aviso de *drift*.

**Por fazer / pendente:**
- Modo "só copiar" (copiar para `Imported` sem imprimir): adiado a pedido do utilizador ("por agora vamos deixar isso estar"). Hipóteses: macro adicional ou fork do KlipperScreen com botão; nada decidido nem verificado.
- Verificar a licença do KlipperScreen antes de qualquer fork.
- Testar com Fluidd (não testado).
- Testar com mais sistemas de ficheiros (exFAT, NTFS, ext4) e pens grandes em máquina real; só FAT32 está confirmado.
- Garantir os bits de execução nos `.sh` no repositório.
- Permissão de reboot do host a partir do KlipperScreen (erro de autenticação), independente deste pacote.

**Problemas conhecidos / limitações:**
- Só uma pen de cada vez (um ponto de montagem); com várias partições só a primeira é montada.
- Só uma instância Klipper por máquina.
- Retirar a pen durante os poucos segundos da cópia cancela o arranque da impressão com mensagem de erro; depois de a impressão arrancar é seguro.
- KlipperScreen só atualiza uma pasta aberta com eventos por ficheiro: botão de refresh ao inserir/retirar a pen com a pasta `USB` aberta. Tocar num ficheiro de uma pen já retirada não faz nada e mostra erro.
- Ficheiros já existentes em `gcodes/USB` ficam escondidos enquanto houver uma pen montada.
- Outros automounters (udisks2, autofs, `fstab`) não são removidos; o `doctor.sh` avisa.
