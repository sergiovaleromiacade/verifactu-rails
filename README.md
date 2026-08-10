# verifactu-rails

Integración con **VERI\*FACTU** (AEAT) para aplicaciones Rails: libro registro
encadenado, remisión a la AEAT y reconciliación de lo anotado.

Es una librería, no un sistema de facturación: calcula la huella encadenada,
genera el XML de los registros y habla con la AEAT por TLS mutuo. No numera
facturas, no calcula impuestos y no emite PDF.

> **Estado: en desarrollo, sin release público.** Ejercitada de punta a punta
> contra el entorno de pruebas de la AEAT —altas encadenadas, lotes, anulación,
> rectificativa, subsanación y reconciliación—. La API puede cambiar sin aviso.

**Solo modalidad VERI\*FACTU** (remisión continua). El modo NO VERI\*FACTU
exigiría firma XAdES y registro de eventos, y no se implementa; la AEAT contempla
esta reducción de alcance (FAQs Desarrolladores v1.3, ap. 15, nota 1). Fuera de
alcance: Facturae/B2G, TicketBAI/Batuz, TPV.

Usar esta gema no te hace cumplidor del RD 1007/2023 ni de la Orden HAC/1177/2024.
Quién responde de qué está en **[COMPLIANCE.md](COMPLIANCE.md)**, y conviene
leerlo antes de poner esto en producción.

## Requisitos

- Ruby >= 3.0, Rails >= 7.0
- Certificado del obligado tributario en PKCS12. Vale el de representante, que es
  el camino contrastado contra el servicio real. El de sello de entidad también
  está soportado (la AEAT le da endpoints propios); con él, declara `sello: true`
  explícitamente en `Transporte`.

## Instalación

```ruby
# Gemfile
gem 'verifactu-rails'
```

```sh
rails g verifactu:install
rails db:migrate
```

El generador deja la migración del libro y `config/initializers/verifactu.rb`. La
migración no copia el esquema: hereda de `VerifactuRails::Libro::Migracion`, así
que lo que instalas es exactamente lo que ejercita la suite de tests de la gema.

## Puesta en marcha

### 1. Identifica tu SIF

En el initializer que dejó el generador. Describe **tu** sistema, no esta gema:
verifactu-rails es un componente del SIF, no el SIF. Viene con valores inválidos
a propósito, para que falle pronto en vez de remitir una identificación
inventada.

```ruby
VerifactuRails::Libro.configure do |c|
  c.productor_nombre = 'Tu Empresa SL'   # quién PRODUCE el software
  c.productor_nif    = '89890001K'
  c.nombre_sistema   = 'TuFactura'
  c.id_sistema       = '01'              # dos posiciones, mayúscula o dígito
  c.version          = TuApp::VERSION
  c.entorno          = Rails.env.production? ? :produccion : :pruebas

  # Las anomalías del art. 7.i) no interrumpen la facturación, pero si no las
  # mandas a algún sitio que mires, se pierden.
  c.al_detectar_anomalia = ->(anomalias, registro) { Rails.logger.warn(...) }
end
```

### 2. Abre una cadena por fuente de facturación

Una vez, y a conciencia: en un seed, una tarea rake o tu panel de administración.
Nunca en un initializer. Cada tienda, TPV o sede es un SIF virtual distinto y
lleva su propia cadena.

```ruby
VerifactuRails::Libro::Cadena.abrir!(
  numero_instalacion: 'TIENDA-VALENCIA-20260807120000',
  nif_obligado: '89890001K', nombre_obligado: 'Tu Empresa SL'
)
```

El `numero_instalacion` **no se autogenera nunca** y no se reutiliza jamás, ni al
reinstalar el mismo software en la misma máquina. Guárdalo en tu modelo (la
tienda, el TPV) para recuperar la cadena después.

### 3. Anota cada factura

```ruby
cadena = VerifactuRails::Libro::Cadena.find_by!(numero_instalacion: tienda.numero_instalacion)

registro = cadena.anotar_alta!(
  id_emisor: '89890001K', num_serie: 'FA/2026/0001',
  fecha_expedicion: Date.current, nombre_razon_emisor: 'Tu Empresa SL',
  tipo_factura: 'F1', descripcion_operacion: 'Servicios de agosto',
  desglose: [VerifactuRails::Detalle.new(base_imponible: BigDecimal('100.00'),
                                         calificacion: 'S1',
                                         tipo_impositivo: BigDecimal('21.00'),
                                         cuota_repercutida: BigDecimal('21.00'))],
  cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
  fecha_hora_gen: Time.now,
  destinatarios: [VerifactuRails::Destinatario.new(nombre_razon: 'Cliente SL',
                                                   nif: '89890002E')]
)

registro.qr_url   # ya disponible: el QR no depende de la AEAT
```

Calcula la huella, encadena y genera el QR en una transacción con la fila de la
cadena bloqueada. Es síncrono a propósito: el encadenamiento no se puede diferir,
aunque el envío sí. También hay `anotar_anulacion!`.

### 4. Envía

```ruby
class EnviarRemesaJob < ApplicationJob
  def perform(numero_instalacion)
    cadena = VerifactuRails::Libro::Cadena.find_by!(numero_instalacion: numero_instalacion)
    certificado = VerifactuRails::Certificado.desde_pkcs12(bytes_del_p12, password)
    transporte  = VerifactuRails::Transporte.new(
      certificado: certificado, entorno: VerifactuRails::Libro.configuracion.entorno
    )

    VerifactuRails::Libro::Remesa.new(cadena, transporte: transporte).enviar!
    # => #<Resultado estado: :enviado|:esperando|:nada_pendiente|:bloqueada_por_rechazo>
  end
end
```

La remesa no recibe registros: coge de la base de datos lo que esa cadena tenga
pendiente. Encólalo tras `anotar_alta!` y ponle además un cron de seguridad por
si un job se perdió; es idempotente, y un duplicado cuenta como éxito.

Construye certificado y transporte **dentro del job**, no al arrancar:
`Transporte` no guarda conexión (reutilizarlo no ahorra ningún handshake) y
`Certificado` comprueba la caducidad al construirse, que es un aviso que pierdes
si lo cacheas durante meses.

### 5. Reconcilia

La respuesta a un envío dice si la AEAT **aceptó** el registro; no dice qué queda
almacenado después. La consulta añade `Anulado`, un estado que el canal de envío
ni siquiera puede expresar.

```ruby
informe = VerifactuRails::Libro::Reconciliacion
          .new(cadena, transporte: transporte)
          .revisar(ejercicio: 2026, periodo: 8)

informe.cuadra?      # => true si el libro y la AEAT dicen lo mismo de cada factura
informe.divergencias # => [#<Divergencia tipo: :no_consta, num_serie: 'FA/7', ...>]
```

Solo lee: nunca corrige el libro. Los tipos de divergencia son `:no_consta`,
`:huella_distinta`, `:estado_distinto`, `:consta_sin_enviar` y `:solo_en_aeat`.

## Lo que conviene saber antes de integrarlo

- **El libro local es el sistema de registro, no una caché.** La consulta de la
  AEAT devuelve una foto por factura, no el histórico: una subsanación sustituye
  al alta original y desaparece de allí. Si pierdes la tabla, el histórico de tu
  cadena no existe en ninguna otra parte. Respáldala.
- **Bifurcar la cadena es imposible por un índice único**, no por el lock. La
  AEAT acepta una cadena bifurcada sin avisar, así que esa restricción es la
  única red que hay.
- **Una anomalía nunca interrumpe la facturación.** El autochequeo del art. 7.i)
  se anota y se notifica, pero no lanza: la norma dice que la facturación "nunca
  debe interrumpirse". Con datos inválidos sí se falla, que ahí tampoco hay
  factura que emitir.
- **Un rechazo detiene la cadena.** Lo rechazado no consta en la AEAT y todo lo
  que encadena detrás apuntaría a un eslabón inexistente. Resolverlo es una
  decisión de negocio.
- **Agrupar no es el modo normal.** Las FAQs exigen remisión "inmediata o sin
  demora apreciable"; el tope de 1000 por envío es un techo para quien factura
  rápido, no un objetivo.
- **`Float` está prohibido** en importes: usa `BigDecimal`, `Integer` o `String`.
  La huella se calcula sobre el string del importe y la AEAT la recalcula sobre
  el XML, así que el importe tiene que ser exacto y su formateo determinista;
  `Float` no da ninguna de las dos cosas. El redondeo se fija explícitamente a
  `ROUND_HALF_UP` porque `BigDecimal.mode` es estado global del proceso.
- **Los espacios al borde se rechazan**, no se recortan. Es más estricto que la
  norma a propósito: casi siempre son un defecto de los datos de origen.
- **Nunca `VERIFY_NONE`.** Desde noviembre de 2025 la AEAT sirve con CA públicas,
  así que `ca_file` no hace falta. Si falla, sospecha del almacén del sistema o
  de un proxy que intercepte el TLS.
- **Los números de factura anulada no se reutilizan.** La excepción es la
  subsanación, que reusa el mismo `IDFactura` a propósito con `subsanacion: 'S'`.

El porqué de cada una, con lo que se comprobó contra el servicio real, está en
[doc/FUENTES.md](doc/FUENTES.md).

## Tipos de factura

`tipo_factura:`. Las descripciones son literales del XSD oficial, que va
versionado en el repo:

| Clave | Qué es | Destinatario | Exige además |
|---|---|---|---|
| `F1` | Factura (art. 6, 7.2 y 7.3 del RD 1619/2012) | obligatorio | — |
| `F2` | Factura simplificada y facturas sin identificación del destinatario (art. 6.1.d) | **prohibido** | — |
| `F3` | Factura emitida en sustitución de facturas simplificadas facturadas y declaradas | obligatorio | `facturas_sustituidas:` (opcional) |
| `R1` | Rectificativa (art. 80.1 y 80.2 y error fundado en derecho) | obligatorio | `tipo_rectificativa:` |
| `R2` | Rectificativa (art. 80.3) | obligatorio | `tipo_rectificativa:` |
| `R3` | Rectificativa (art. 80.4) | obligatorio | `tipo_rectificativa:` |
| `R4` | Rectificativa (resto) | obligatorio | `tipo_rectificativa:` |
| `R5` | Rectificativa en facturas simplificadas | **prohibido** | `tipo_rectificativa:` |

La columna del destinatario no es un matiz: en `F2` y `R5` informarlo es un
error, y en los demás omitirlo también. `facturas_rectificadas:` es opcional pero
exclusiva de `R1`–`R5`, y `Cupon` solo se admite con `R1` o `R5`.

### Rectificativas: sustitutiva o incremental

- **`'S'` sustitutiva** — la factura reexpresa el importe corregido completo, así
  que hay que declarar el original en `importe_rectificacion:`.
- **`'I'` incremental** — los importes ya *son* la diferencia, y
  `importe_rectificacion:` se rechaza.

El XSD deja casi todos estos campos opcionales, así que estas reglas las impone
la gema: sin ellas se monta un `R1` válido para el esquema que la AEAT rechaza
con un error mucho menos claro.

## Calificación de cada línea del desglose

Cada `Detalle` lleva **o** `calificacion:` **o** `exenta:`, exactamente una. No es
una preferencia de la gema: el esquema las modela como un `choice`, así que
informar las dos —o ninguna— produce un documento inválido.

| Clave | Qué significa |
|---|---|
| `S1` | Operación sujeta y no exenta, **sin** inversión del sujeto pasivo |
| `S2` | Operación sujeta y no exenta, **con** inversión del sujeto pasivo |
| `N1` | Operación no sujeta (art. 7, 14, otros) |
| `N2` | Operación no sujeta por reglas de localización |

```ruby
# Lo normal: sujeta y no exenta, con su tipo y su cuota.
Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: 'S1',
            tipo_impositivo: BigDecimal('21.00'),
            cuota_repercutida: BigDecimal('21.00'))

# Exenta: el importe va en base_imponible y NO se informa tipo ni cuota.
Detalle.new(base_imponible: BigDecimal('100.00'), exenta: 'E1')
```

Tres reglas que conviene tener presentes, porque la AEAT tiene un código de error
para cada una:

- **`N1`, `N2` y las exentas no admiten** `tipo_impositivo:`, `cuota_repercutida:`
  ni recargo. Informarlos da error 1237 o 1238.
- **`S2` (inversión del sujeto pasivo) solo cabe en `F1`, `F3` y `R1`–`R4`.**
- **`E7` y `E8` solo existen con IGIC.** Para IVA, las exenciones son `E1`–`E6`.

### Causas de exención

El XSD las lleva desnudas, sin descripción. La correspondencia es esta, en
palabras de la propia AEAT, y los artículos son de la Ley 37/1992 del IVA:

| Clave | Texto de la AEAT | De qué trata ese artículo |
|---|---|---|
| `E1` | *exenta por el artículo 20* | Exenciones en operaciones interiores |
| `E2` | *exenta por el artículo 21* | Exportaciones de bienes |
| `E3` | *exenta por el artículo 22* | Operaciones asimiladas a las exportaciones |
| `E4` | *exenta por los artículos 23 y 24* | Zonas y depósitos francos, regímenes aduaneros y fiscales |
| `E5` | *exenta por el artículo 25* | Entregas intracomunitarias |
| `E6` | *exenta por otros* | El resto |

La AEAT añade que **si no se dispone de esa información basta con indicar que la
operación es exenta**. Ojo: eso vale para el libro registro, pero el esquema de
VERI\*FACTU exige un valor concreto en `OperacionExenta`, así que en la práctica
hay que elegir uno; `E6` es el cajón previsto para ello.

El mapeo sale de la documentación del SII, que comparte esta lista de códigos,
porque la documentación técnica de VERI\*FACTU no la desarrolla. Las FAQs de la
propia AEAT sobre el libro registro lo corroboran para los dos casos que citan
con nombre: exportaciones (`E2`) y entregas intracomunitarias (`E5`).

### Impuesto, régimen y tipos

`impuesto:` y `clave_regimen:` van **en cada línea del desglose**, no en la
factura: son parámetros de `Detalle`. En los ejemplos de arriba no se ven porque
tienen valor por defecto —`'01'` en los dos, IVA y régimen general—, que es el
caso normal. Explícitos:

```ruby
Detalle.new(base_imponible: BigDecimal('50.00'), calificacion: 'S1',
            impuesto: '03', clave_regimen: '01',        # IGIC
            tipo_impositivo: BigDecimal('7.00'),
            cuota_repercutida: BigDecimal('3.50'))
```

Cada línea acaba en su propio `<DetalleDesglose>` con su `<Impuesto>`, así que
**una misma factura puede mezclar impuestos**. Los valores son `01` IVA, `02`
IPSI, `03` IGIC y `05` otros.

### Clave de régimen

Y aquí está la trampa: **qué significa `clave_regimen:` depende del impuesto**.
Las claves `18`, `19` y `20` no quieren decir lo mismo en IVA que en IPSI, así
que copiar un valor de un ejemplo de IVA a una línea de IPSI declara otra cosa.

Qué admite cada impuesto (la gema lo valida y rechaza el resto):

| Impuesto | Claves admitidas |
|---|---|
| `01` IVA | `01`–`11`, `14`, `15`, `17`, `18`, `19`, `20` (lista L8A) |
| `03` IGIC | las de L8A más `20` (operaciones sujetas al IPSI) y `21` (régimen simplificado) |
| `02` IPSI | solo `01`, `08`, `11`, `18`, `19`, `20`, y con significado propio |
| `05` Otros | **ninguna**: el campo no se puede informar en absoluto |

Las de IPSI, en palabras de la AEAT: `01` régimen general, `08` operaciones
sujetas al IGIC/IVA, `11` arrendamiento de local de negocio, `18` operaciones del
art. 73.4 y 5 de la Ordenanza fiscal IPSI (solo Ceuta), `19` operaciones
interiores exentas y `20` régimen de estimación objetiva.

Para IVA las más frecuentes son `01` régimen general, `02` exportación, `07`
criterio de caja, `11` arrendamiento de local de negocio sujeto a retención y
`18` recargo de equivalencia. La lista completa con su descripción es la L8A de
los Diseños de registro de la AEAT; aquí no se reproduce entera porque cambia con
las versiones y no queremos una copia que envejezca en silencio.

Cada clave arrastra además sus propias reglas, que la gema aplica antes de
enviar (Validaciones ap. 15.6): con `02` solo cabe `OperacionExenta`; con `03`,
si hay calificación, solo `S1`; con `04`, `S2` o exenta; con `07` no valen `S2`,
`N1`, `N2` ni las exenciones `E2`–`E5`; con `08` y con `20` en IGIC tiene que ser
`N2`; con `11` el único tipo admitido es el 21; con `10` la factura tiene que ser
`F1` y todos los destinatarios llevar NIF; y con `14` hace falta `fecha_operacion:`
posterior a la de expedición y destinatarios con NIF de administración pública.

Dos avisos sobre esto:

- **En IPSI no aplican.** La norma las acota a IVA e IGIC, y en IPSI las claves
  `18`, `19` y `20` significan otra cosa. La gema respeta esa frontera.
- **La clave `06` no se puede usar.** Exige `BaseImponibleACoste`, un campo que
  la gema no emite, así que se rechaza en local con ese motivo en vez de armar un
  registro que la AEAT va a rechazar igual.

Los tipos impositivos de IVA y el recargo de equivalencia que admite cada uno se
validan contra la fecha de la operación:

| Tipo | Recargo de equivalencia admitido | Vigencia del tipo |
|---|---|---|
| `21.00` | `5.20` o `1.75` | siempre |
| `10.00` | `1.40` | siempre |
| `4.00` | `0.50` | siempre |
| `0.00` | `0.00`, y solo entre 01-01-2023 y 30-09-2024 | siempre |
| `5.00` | `0.50` hasta 31-12-2022; `0.62` desde 01-01-2023 | **01-07-2022 – 30-09-2024** |
| `2.00` | `0.26` | **01-10-2024 – 31-12-2024** |
| `7.50` | `1.00` | **01-10-2024 – 31-12-2024** |

Las dos columnas se validan por separado: un tipo puede estar vigente y aun así
rechazarse el recargo que le acompañe.

Los tres marcados fueron rebajas temporales. Y aquí hay una consecuencia que
sorprende: como `FechaExpedicionFactura` no puede ser anterior al 28-10-2024,
**el 5 % ya no es declarable** salvo que informes una `fecha_operacion:` dentro
de su ventana. Es el origen de los errores 1235 y 1236 de la AEAT.

## Componentes

| Módulo | Qué hace |
|---|---|
| `Libro` | Capa Rails: libro registro, encadenamiento bajo lock y autochequeo |
| `Libro::Remesa` | Envío por lotes de lo pendiente, con control de flujo y reintentos |
| `Libro::Reconciliacion` | Contraste de solo lectura contra lo que la AEAT tiene anotado |
| `Huella` | Serialización canónica y SHA-256 del registro |
| `RegistroAlta` / `RegistroAnulacion` | El registro: calcula su huella y emite su XML |
| `Envio` | Documento `RegFactuSistemaFacturacion` (lote de hasta 1000) |
| `Consulta` / `RespuestaConsulta` | Consulta de lo anotado, con paginación |
| `Certificado` / `Transporte` | PKCS12, caducidad y cliente HTTP con TLS mutuo |
| `QR` | URL de cotejo. La AEAT no la devuelve: la construye el SIF |
| `Detalle` / `Desglose` / `Destinatario` / `Tercero` | Piezas del registro |
| `Importe` / `Formato` | Importes, fechas y NIF normalizados en un único sitio |

## Uso sin Rails

El núcleo no depende de Rails ni de ActiveRecord: `require 'verifactu-rails'` da
`Huella`, los registros, `Envio`, `Consulta` y `Transporte` para construir y
remitir el XML por tu cuenta. La capa `Libro` se carga aparte
(`require 'verifactu_rails/libro'`) y sí exige ActiveRecord.

## Tests

```sh
createdb verifactu_rails_test   # solo la primera vez
bundle exec rake test
```

Los tests del libro necesitan una base de datos de verdad: hay que demostrar que
un índice único impide bifurcar la cadena y que el lock serializa, y eso no se
simula con dobles. Si no la encuentra, la suite **aborta** en vez de saltárselos.
Si el nombre de la base no parece de tests, también aborta: la suite vacía tablas
y no debe correr contra datos reales.

Incluye los tres vectores oficiales de la AEAT (Especificaciones huella v0.1.2,
ap. 6), verificación cruzada de la huella contra `josemmo/Verifactu-PHP` y
`mybooking-es/verifactu-rb`, y validación del XML contra los XSD oficiales,
versionados en
[lib/verifactu_rails/schemas](lib/verifactu_rails/schemas/PROCEDENCIA.md).

## Licencia

MIT. Se distribuye sin garantía de ningún tipo; ver [LICENSE](LICENSE).
