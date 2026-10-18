# Talktrail

Transcripción local de llamadas para macOS. Graba tu micrófono y el audio de la llamada (Zoom, Teams, Meet, lo que sea), transcribe en el equipo y deja un archivo Markdown en `~/Documents/Transcripciones`. **Ningún audio ni texto sale de la Mac.**

Por ahora es la única función: no hay supresión de ruido ni cambio de acento.

## Por qué no usa un driver de audio

Muchas herramientas para llamadas instalan un driver de audio virtual (un plug-in HAL de Core Audio) que hay que elegir como micrófono o parlante en Zoom, Teams o Meet. Eso hace falta cuando se **modifica** el audio, por ejemplo para quitar ruido. Para **solo transcribir** no hace falta: Talktrail lee el micrófono como cualquier app y captura lo que suena por los parlantes con un *process tap* de Core Audio (macOS 14.4+). No instala nada en `/Library`, no necesita permisos de administrador, no puede tumbar `coreaudiod` y el usuario no tiene que cambiar el dispositivo en la app de llamadas.

## Cómo funciona

```
Micrófono ──► AVAudioEngine ──────────────► SpeechAnalyzer ("Yo") ──────┐
                                                                         ├─► borrador en vivo (temporal)
Audio del sistema ──► process tap ──► SpeechAnalyzer ("Remoto") ────────┘
                           │                                              al detener:
                           └──► audio remoto (temporal, 16 kHz) ──► diarización (FluidAudio)
                                                                         │
                                       ~/Documents/Transcripciones/transcripcion-….md ◄─┘
```

- **Transcripción:** `SpeechAnalyzer` / `SpeechTranscriber` de Apple (macOS 26), 100 % en el dispositivo. Un analizador por canal.
- **Eco:** sin audífonos el micrófono también capta la llamada. Se descartan las frases de "Yo" que repiten, en el mismo momento, una frase remota.
- **Identificación de personas:** al detener, el audio remoto se procesa con [FluidAudio](https://github.com/FluidInference/FluidAudio): segmentación pyannote, embeddings WeSpeaker y agrupamiento VBx, sobre Core ML. Cada palabra se asigna a "Persona 1", "Persona 2"…, y si cambia la persona a mitad de frase, la frase se divide. El micrófono queda como "Yo". Procesar una hora de audio toma uno o dos minutos.
- **Archivos:** el borrador en vivo se escribe en la carpeta temporal privada del usuario y se borra al generar la transcripción final. El audio remoto temporal también se borra. Si la app se cierra de golpe, en la próxima grabación el borrador se recupera como `…-recuperada.md`.

Ejemplo de salida:

```markdown
# Transcripción

- **Inicio:** 2026-10-17 10:12:25
- **Idioma:** es_MX
- **Participantes:** Yo (micrófono) · Persona 1–2 (audio de la llamada)

---

**[10:12:40] Persona 1:** Buenos días a todos, gracias por conectarse.

**[10:12:46] Yo:** Gracias. Empecemos con el presupuesto.
```

## Privacidad y red

| Qué | Dónde | Red |
|---|---|---|
| Transcripción final | `~/Documents/Transcripciones` (permisos `600`) | — |
| Borrador en vivo y audio remoto temporal | carpeta temporal del usuario; se borran al terminar | — |
| Modelo de voz de Apple (uno por idioma) | lo instala macOS la primera vez que se usa un idioma | descarga única desde Apple, solo el modelo |
| Modelos de identificación de personas (21 MB) | dentro de `Talktrail.app` | **ninguna**: la app fuerza `ModelHub.offlineMode` |

## Requisitos

- macOS 26 o posterior. El build por defecto es para Apple Silicon.
- Command Line Tools con Swift 6.2 o posterior (no hace falta Xcode).

## Compilar

```sh
scripts/build.sh
```

Deja `build/Talktrail.app` (la app de barra de menú) y `build/talktrail` (la CLI), firmados ad-hoc. Para distribuirlo a otros equipos, firma con Developer ID y notariza:

```sh
SIGN_IDENTITY="Developer ID Application: <Nombre> (<TEAMID>)" scripts/build.sh
```

### Modelos

`Models/speaker-diarization` ya está incluido (revisión `df2625ac…`; los SHA-256 coinciden con su `provenance.json`). Para volver a descargarlo:

```sh
swift build -c release --product talktrail
.build/release/talktrail fetch-models /tmp/talktrail-models
cp -R /tmp/talktrail-models/speaker-diarization Models/
```

## Uso

**App:** abre `Talktrail.app`. Aparece un ícono de onda en la barra de menú, desde donde se puede:

- Iniciar y detener la transcripción.
- Elegir el idioma.
- Activar o desactivar el micrófono, el audio de la llamada y la identificación de personas.
- Abrir la última transcripción o la carpeta de transcripciones.

La primera vez macOS pide permiso de **Micrófono** y de **Grabación de audio del sistema**.

**CLI:**

```sh
build/talktrail record -l es-MX          # graba hasta Ctrl+C
build/talktrail transcribe reunion.m4a   # transcribe un archivo e identifica a las personas
build/talktrail locales                  # idiomas disponibles
build/talktrail --help
```

`talktrail record` desde una terminal solo captura bien el micrófono. iTerm2 y Terminal no declaran `NSAudioCaptureUsageDescription`, así que macOS les entrega silencio en lugar del audio del sistema. Para grabar llamadas usa la app.

## Limitaciones conocidas

- **Un idioma por sesión.** Si en la llamada se mezclan idiomas, lo que se diga en el otro idioma sale mal transcrito.
- **Nombres:** la identificación distingue voces, no nombres; "Persona 1" se renombra a mano. Con intervenciones cortas (≈2 s) de voces parecidas, el modelo puede atribuirlas a la persona vecina o juntar dos voces en una. En las pruebas con voces sintéticas pasó con dos voces masculinas. Hay que validarlo con llamadas reales.
- **Sin audífonos**, el filtro de eco descarta las repeticiones claras, pero si hablas encima de otra persona, esa frase de "Yo" puede incluir parte de lo que dijo el otro.
- **Marcas de tiempo:** precisión de alrededor de ±0.5 s.

## Problemas frecuentes

- **`swift build` falla con `extra argument 'swiftLanguageModes'`:** las Command Line Tools quedaron con archivos viejos de Swift 5.10. Arreglo:
  `sudo rm /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface`
- **La parte "Remoto" sale vacía:** falta el permiso en Ajustes del Sistema > Privacidad y seguridad > Grabación de pantalla y audio del sistema. Sin ese permiso, macOS entrega silencio en vez de un error. La app avisa después de 45 s de silencio.
- **macOS vuelve a pedir los permisos tras cada build:** pasa con la firma ad-hoc, porque la identidad cambia en cada compilación. Con Developer ID no ocurre.
- **Diagnóstico:** `TALKTRAIL_DEBUG=1` muestra el nivel de audio de cada canal, los tiempos por palabra y los turnos de cada persona. Para la app: `open --env TALKTRAIL_DEBUG=1 --stderr /tmp/talktrail.log build/Talktrail.app`.

## Licencia

Talktrail se distribuye bajo la licencia [Apache-2.0](LICENSE). Las atribuciones de terceros están en [NOTICE](NOTICE). `scripts/build.sh` copia ambos archivos, junto con las licencias de FluidAudio, a `Talktrail.app/Contents/Resources/Licenses`.

### Licencias de terceros

- [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.7: Apache-2.0. Se compila sin el *trait* `NemoTextProcessing`, así que no se enlaza su binario precompilado.
- Modelos `FluidInference/speaker-diarization-coreml`: CC-BY-4.0, derivados de [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1). Requieren atribución al distribuirlos.
