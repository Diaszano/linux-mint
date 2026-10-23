# VAIO FE16 · Linux Mint 22.x · Ryzen 7 5825U (24 GB)

Setup **pós-formatação** para desenvolvimento backend e Android, com preferência por estabilidade sob carga. Este conjunto foi pensado para **Linux Mint 22.3 Cinnamon (base Ubuntu 24.04/Noble)**, Ryzen 7 5825U (8 núcleos, 16 threads, TDP nominal 15 W), RAM de 24 GB e gráficos AMD integrados.

> **Faça backup antes de formatar.** A formatação apaga seus dados. Execute o script somente **depois de instalar o Mint no SSD**, já na conta do usuário comum. Ele altera configurações do sistema usando `sudo`; leia o `setup.sh` antes de executar. Não promete impedir 100% dos travamentos, especialmente por bugs gráficos, aquecimento, falhas de disco ou firmware.

## Instalação

Extraia o arquivo ZIP inteiro para sua pasta pessoal e execute no terminal dentro da pasta:

```bash
bash setup.sh --check   # examinar sem modificar
bash setup.sh           # instalar/configurar
# alternativas:
bash setup.sh --no-docker
bash setup.sh --no-earlyoom
bash setup.sh --skip-mise
```

Quando terminar, **reinicie a sessão (preferencialmente reinicie o computador)**, porque a nova participação no grupo `kvm` só é reconhecida após novo login. Abra um terminal novo e execute:

```bash
dev-doctor
mise doctor
swapon --show
zramctl
ls -l /dev/kvm
```

Se o sistema não expuser `svm` no `/proc/cpuinfo` ou não existir `/dev/kvm`, procure a opção **SVM Mode / AMD-V / Virtualization** no BIOS/UEFI do VAIO e habilite-a. A opção exata depende do firmware. Android Emulator deve usar uma imagem **x86_64** do Android, não uma imagem ARM, para aproveitar a virtualização nesse processador.

## Configurações aplicadas

| Área | Configuração e observação |
|---|---|
| zram | `zram-tools`, LZ4, `PERCENT=50` (cerca de **12 GB lógicos**, não 12 GB reservados fisicamente), prioridade 100 |
| Swap | `vm.swappiness=100` e `vm.page-cluster=0`; preserva qualquer swap em disco como recurso de emergência, **não o remove** |
| Memória crítica | Instala `earlyoom` com limiares de 5% quando `systemd-oomd` não estiver ativo; sob pressão extrema **pode encerrar processos** |
| KVM | Módulo `kvm_amd`, grupo `kvm` e `cpu-checker`; requer suporte ativado no BIOS |
| Gráficos | Drivers Mesa/Vulkan da distribuição. Não instala pacote proprietário de GPU AMD |
| Docker | `docker.io` + `docker-compose-v2` do Ubuntu, sem colocar usuário no grupo `docker` (grupo dá privilégios equivalentes a root) |
| Mise | Instala/ativa mise para Bash e, se já existir `.zshrc`, Zsh; **não** instala versões globais de linguagens por conta própria |
| Gradle | 4 workers, heap Java 3 GB, build cache, paralelismo entre projetos, daemon para após 15 minutos ocioso |
| Monitoramento | `btop`, `htop`, `lm-sensors`, `nvme-cli`, `smartmontools`, `sysstat`, `powertop`, `vulkan-tools` e diagnóstico `dev-doctor` |

Arquivos do sistema alterados: `/etc/default/zramswap`, `/etc/sysctl.d/90-vaio-dev-zram.conf`, e potencialmente `/etc/default/earlyoom`. Backups dos arquivos preexistentes ficam em `/var/backups/vaio-fe16-dev-setup/<data-hora>/`. O script também adiciona um bloco próprio a `~/.gradle/gradle.properties`, acrescenta o hook de mise ao shell se ele não existir, adiciona PATH a `~/.profile` se necessário e instala utilitários em `~/.local/bin`.

Os limites de CPU abaixo são **quotas de tempo**, não reserva de núcleos nem um bloqueio de todos os programas do computador. Em build, a quota de `800%` equivale a até **8 threads lógicas a 100%** ao longo do período de contabilização; o escalonador pode distribuir a carga por mais CPUs. O comportamento depende de cgroups v2 e da configuração do `systemd --user`.

## Builds e emuladores sem monopolizar o computador

```bash
# Build Gradle de projeto Android/Kotlin:
dev-build ./gradlew assembleDebug --no-daemon

# Go:
dev-build go test ./...
dev-build go build ./...

# Node/TypeScript:
dev-build npm run build

# Python:
dev-build python -m pytest

# .NET:
dev-build dotnet build

# Qualquer outro programa pesado:
dev-run heavy meu-comando --minhas-opcoes

# Mostrar AVDs e executar um Android Emulator com KVM:
dev-emulator --list
dev-emulator Pixel_7_API_35
```

Perfis implementados em `bin/dev-run`:

| Perfil | Quota CPU | Memória (MemoryHigh) | Máximo (MemoryMax) |
|---|---:|---:|---:|
| `build` | 800% | 7 GiB | 9 GiB |
| `emulator` | 400% | 5 GiB | 6 GiB |
| `heavy` | 600% | 6 GiB | 8 GiB |

* **MemoryHigh** provoca reclaim/pressão, e **MemoryMax** é um teto rígido: um processo dentro do grupo pode sofrer OOM ou ser encerrado antes de o sistema inteiro ficar sem memória. Não significa que uma compilação sempre passará: builds muito grandes talvez precisem de limites maiores.
* Os limites abrangem os comandos iniciados pelos wrappers e os processos filhos que **permanecerem no mesmo cgroup**. Builds disparados diretamente no IDE e emuladores iniciados pelo botão **Run** do Android Studio **não entram automaticamente nesses limites**.
* `dev-build` sugere 8 workers para Go/Rust/CMake via variáveis de ambiente no **processo do build**, sem forçar esse valor no sistema inteiro.
* `dev-build ./gradlew ... --no-daemon` evita manter um daemon Gradle desse comando vivo após o build. O Gradle ainda pode criar processo temporário para honrar os parâmetros de JVM.
* Se `systemd-run --user --scope` falhar (por exemplo, o sistema não delegar controles de cgroup), **o wrapper não executa seu comando sem limite silenciosamente**. Corrija o erro do systemd ou, se souber do risco, use `DEV_LIMITS_DISABLED=1 dev-build COMANDO` para rodar apenas com prioridade reduzida.

O `dev-emulator` inicia o Android Emulator com **4 vCPUs, 3072 MB de RAM, GPU automática e animação de boot desativada**. Evite mais de um emulador ao mesmo tempo enquanto estiver executando builds grandes. Use dispositivos virtuais leves (Pixel pequeno, resolução 1080p ou menor, imagem x86_64) e, se necessário, um celular Android físico via USB para testar.

## Instalar o Android Studio

Por robustez, o instalador **não baixa automaticamente o Android Studio**: o pacote oficial `.tar.gz` é atualizado frequentemente e a configuração inicial depende da aceitação dos termos do SDK. Use [a página oficial do Android Studio](https://developer.android.com/studio), extraia o Linux `.tar.gz` para `~/Applications` ou `/opt`, abra o executável `android-studio/bin/studio` e siga o assistente. Instale pelo **SDK Manager**: Android SDK Platform-Tools, Android Emulator, Android SDK Build-Tools e a plataforma/imagem x86_64 desejada. Execute `dev-doctor` novamente após isso.

Se desejar emulador x86_64 de 3 GB, crie-o em **Tools → Device Manager → Create device**, e depois rode-o pelo terminal com `dev-emulator NOME_DO_AVD` para aplicar os limites. Para os builds pelo botão do Android Studio, as configurações globais Gradle já estabelecem limites de workers e heap do daemon, **mas não são um teto de RAM de todo o conjunto do IDE**. É possível ajustar a RAM do próprio IDE pelo menu **Help → Change Memory Settings** (quando disponível) e desativar plugins desnecessários; não altere o heap do IDE às cegas.

## Instalar linguagens com mise

Abra terminal novo. Não são fixadas versões globais no setup para respeitar versões de cada projeto (`mise.toml`, `.tool-versions`). Exemplo **opcional**:

```bash
mise use --global go@latest
mise use --global node@lts
mise use --global python@3.13
mise use --global java@21
mise use --global dotnet@10
mise doctor
```

`mise` gerencia as versões por projeto. Um projeto pode usar `mise use go@1.26` ou `mise install` caso contenha um `mise.toml` confiável. A JVM integrada ao Android Studio pode ser usada como Gradle JDK mesmo quando há um Java global no mise. Evite misturar vários gerenciadores de versões da mesma linguagem sem necessidade.

## Docker com limites

O setup instala Docker, mas **não impõe um limite global a todos os containers**. Limite-os por serviço no Compose, especialmente Postgres, Valkey e serviços auxiliares:

```bash
# Executar um exemplo opcional, com variavel obrigatoria de senha:
export POSTGRES_PASSWORD='troque-por-uma-senha-forte'
sudo --preserve-env=POSTGRES_PASSWORD docker compose -f compose-limits.example.yaml up -d

# Ver consumo:
sudo docker stats
```

Esse Compose tem limites de CPU e memória, portas restritas a `127.0.0.1` e não deve ser utilizado para produção sem ajustes. Se preferir Docker rootless, consulte a [documentação Docker](https://docs.docker.com/engine/security/rootless/) e revise suporte a limites de cgroup na sua instalação.

## Diagnóstico e manutenção

```bash
# Observar CPU/RAM em tempo real:
btop

# Ver aceleração OpenGL da Radeon:
glxinfo -B

# Checar virtualização:
kvm-ok

# Ver consumo do Docker:
sudo docker stats

# Ver atualizações de firmware disponíveis (opcional):
# fwupdmgr get-devices && fwupdmgr get-updates

# Consultar eventos graves no boot:
journalctl -b -p err --no-pager

# OOM/earlyoom recente:
journalctl -u earlyoom -b --no-pager
```

**Não** são aplicados: overclock/undervolt, `powertop --auto-tune`, CPU governor fixado em `performance`, parâmetros experimentais de `amd_pstate`, desativação de mitigação de segurança, desativação de journaling, `preload/prelink`, alterações invasivas no GRUB, instalação de drivers AMD proprietários ou desativação forçada de swap em disco. Essas medidas podem piorar desempenho sustentado, consumo, segurança ou estabilidade.

O Ryzen 7 5825U tem TDP nominal de 15 W e pode diminuir frequência sob aquecimento/carga prolongada. Limpar entradas de ventilação e manter o SSD com espaço livre são tão importantes quanto otimizações de software.

## Restauração / reversão

O script **não possui desinstalador automático** porque pode haver mudanças do usuário depois da instalação. Para reverter, avalie os backups em `/var/backups/vaio-fe16-dev-setup/`, remova as configurações de `/etc/sysctl.d/90-vaio-dev-zram.conf`, restaure `/etc/default/zramswap` e `/etc/default/earlyoom` a partir dos backups e reinicie as unidades correspondentes. Remova o bloco `# BEGIN VAIO-DEV-SETUP`...`# END VAIO-DEV-SETUP` de `~/.gradle/gradle.properties` se desejar. Desinstale pacotes **somente após confirmar dependências**.

## Referências

* [Linux Mint: versão estável e downloads](https://linuxmint.com/)
* [AMD Ryzen 7 5825U](https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen/ryzen-5000-series/amd-ryzen-7-5825u.html)
* [Android: aceleração por hardware no Linux](https://developer.android.com/studio/run/emulator-acceleration)
* [Android: instalar o Android Studio](https://developer.android.com/studio/install)
* [Gradle: propriedades e workers](https://docs.gradle.org/current/userguide/build_environment.html)
* [mise: instalação](https://mise.jdx.dev/installing-mise.html)
* [zram no Debian](https://wiki.debian.org/ZRam)
