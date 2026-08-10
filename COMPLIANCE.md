# Cumplimiento: qué cubre esta gema y qué te sigue tocando a ti

Este documento delimita responsabilidades. No es asesoramiento legal, no es una
certificación, y **usar `verifactu-rails` no te hace cumplidor** del RD 1007/2023
ni de la Orden HAC/1177/2024. Es un componente de tu sistema de facturación; el
sistema es tuyo.

Las citas normativas de aquí vienen de las fuentes recogidas en
[doc/FUENTES.md](doc/FUENTES.md) (el propio texto de la Orden, las FAQs de
Desarrolladores y los PDF de Validaciones de la AEAT). Antes de apoyarte en
cualquiera de ellas para una decisión con consecuencias, contrástala con el BOE:
esto es documentación de una librería, no una fuente jurídica.

## Quién responde de qué

La pieza que ordena todo lo demás: **la declaración responsable del art. 13 la
firma quien produce el sistema informático de facturación**, y quien produce el
SIF eres tú, no esta gema. Si desarrollas el software para tu propio uso, eres
productor y usuario a la vez; si lo vendes, sigues siendo el productor.

Además, la obligación de trazabilidad recae legalmente sobre el productor y no
solo sobre quien factura (art. 29.2.j LGT). Certificar por declaración
responsable un SIF que no cumple el RD 1007/2023 es sancionable.

Consecuencia práctica: nadie va a mirar el `Gemfile` de tu aplicación para
repartir culpas. Lo que se mira es el sistema que has declarado.

## Alcance: solo VERI\*FACTU

Esta gema implementa **únicamente la modalidad VERI\*FACTU**, la de remisión
continua a la AEAT. No implementa el modo NO VERI\*FACTU, que exigiría firma
XAdES de cada registro y llevar registro de eventos.

Esa reducción de alcance es legítima y la AEAT la contempla explícitamente (FAQs
Desarrolladores v1.3, ap. 15, nota 1). Se refleja en el código: el campo
`TipoUsoPosibleSoloVerifactu` va fijo a `'S'` y **no se puede configurar**.
Declarar `'N'` significaría que tu SIF puede operar en modo no VERI\*FACTU, y eso
te obligaría a un registro de eventos que aquí no existe. Si necesitas `'N'`,
esta no es tu librería.

## Qué pone la gema

| Requisito | Dónde |
|---|---|
| Huella SHA-256 con serialización canónica, alta y anulación | `Huella` |
| Encadenamiento de cada registro con el anterior | `Libro::Cadena#anotar_alta!`, bajo lock |
| Imposibilidad de bifurcar la cadena | índice único `(cadena_id, huella_anterior)` |
| Comprobaciones del art. 7.i) antes de generar cada registro | `Libro::Autochequeo` |
| Orden cronológico de generación | serialización bajo `SELECT … FOR UPDATE` |
| XML conforme a los XSD de la AEAT | `RegistroAlta` / `RegistroAnulacion` / `Envio` |
| Remisión con TLS mutuo al endpoint correcto | `Transporte` |
| Reenvío de lo pendiente, con control de flujo y reintentos | `Libro::Remesa` |
| URL de cotejo del código QR | `QR` |
| Contraste contra lo que la AEAT tiene anotado | `Libro::Reconciliacion` |
| Conservación del registro tal y como se remitió | columna `payload` del libro |

Sobre la última fila, que es la que más peso tiene si algún día hay una
inspección: el libro guarda el **fragmento XML ya construido**, no los argumentos
con que se construyó. Lo que se envía es exactamente lo que se calculó, y la
huella se puede recalcular años después desde las columnas sin volver a derivar
nada.

## Qué NO pone la gema, y tienes que poner tú

- **La declaración responsable.** Ver arriba.
- **El registro de eventos.** No existe. Solo hace falta en modo NO VERI\*FACTU,
  que está fuera de alcance, pero conviene que sepas por qué no está.
- **La imagen del código QR.** La gema construye la URL de cotejo; convertirla en
  un QR y ponerlo en la factura es tuyo. La AEAT no devuelve esa URL: la
  construye el SIF.
- **La factura en sí.** Esto no es un sistema de facturación: no numera, no
  calcula impuestos, no emite PDF ni gestiona clientes.
- **La custodia del certificado.** `Certificado` recibe los bytes ya cargados y
  deliberadamente no sabe leer ficheros ni variables de entorno. Dónde vive el
  `.p12` y quién puede leerlo es decisión y responsabilidad tuyas.
- **El `NumeroInstalacion`.** No se autogenera **nunca**, y no es un descuido: si
  la gema lo inventara, un contenedor que se recrea en cada despliegue abriría
  una instalación por despliegue y la cadena dejaría de demostrar nada. Elegirlo
  —y no reutilizarlo jamás, ni al reinstalar el mismo software en la misma
  máquina— es un acto deliberado tuyo.
- **La conservación y el respaldo del libro.** Ver el apartado siguiente, porque
  es el punto que más se subestima.
- **La política de retención, acceso y borrado** de los datos, y todo lo que
  tenga que ver con protección de datos.

## Tres límites que conviene entender antes de firmar nada

**1. El libro local es el sistema de registro, no una caché.** Está comprobado
contra el servicio real que la consulta de la AEAT devuelve **una foto por
factura, no el histórico**: una subsanación sustituye al alta original y la
anulación sustituye a lo anulado, así que los eslabones intermedios desaparecen.
Si pierdes la tabla `verifactu_registros`, el histórico de tu cadena no existe en
ninguna otra parte. Respáldala como respaldarías la contabilidad.

**2. La AEAT acepta una cadena bifurcada sin avisar.** Comprobado, también contra
el servicio real. No valida el eslabón al recibir, así que un encadenamiento
incoherente se aceptaría en silencio y quedaría anotado. La única red que hay es
el índice único local. Si migras el esquema a mano, o replicas la tabla, o
permites escrituras que esquiven `anotar_alta!`, esa red desaparece y no te vas a
enterar por la AEAT.

**3. Una anomalía de trazabilidad no interrumpe la facturación, por norma.** El
autochequeo del art. 7.i) se anota y se notifica, pero **no lanza excepción**: la
Orden dice que ante una anomalía la facturación "nunca debe interrumpirse".
Traducción operativa: si no enganchas `al_detectar_anomalia` a algo que mires de
verdad, las anomalías se pierden. Que no bloqueen no significa que no importen.

## Cómo demostrar que esto hace lo que dice

Si tienes que justificar el componente ante un cliente o un auditor, esto es lo
que hay:

- **Suite de tests** que incluye un caso con ocho hilos demostrando que la cadena
  no se puede bifurcar (quitando el lock, para que el índice tenga que
  sostenerlo), y validación de todo el XML contra los XSD oficiales de la AEAT,
  que se versionan en el repo con su procedencia documentada.
- **[doc/FUENTES.md](doc/FUENTES.md)**: el registro de qué se ha contrastado
  contra el servicio real de preproducción, con fechas y resultados. Incluye lo
  que salió distinto de lo esperado y lo que sigue siendo suposición.
- **`Libro::Reconciliacion`**: contraste de solo lectura entre tu libro y lo que
  la AEAT tiene anotado, factura a factura.
- **`Registro#huella_cuadra?`**: recalcula la huella desde las columnas
  almacenadas. Si alguien editó una fila por debajo del modelo, se ve.

## Antes de poner esto en producción

Una lista corta de lo que hay que haber decidido, no de lo que hay que programar:

1. Quién firma la declaración responsable y con qué versión del SIF.
2. Qué `NumeroInstalacion` lleva cada fuente de facturación, y quién lo asigna.
   Una por tienda, TPV o sede: son SIF virtuales distintos.
3. Dónde vive el certificado, quién lo puede leer y qué pasa cuando caduque
   (`Certificado#caduca_pronto?` avisa, pero alguien tiene que escucharlo).
4. A dónde van las anomalías del art. 7.i) y quién las mira.
5. Qué se hace cuando un registro es **rechazado**. La remesa detiene la cadena a
   propósito, porque seguir enviando dejaría una cadena incoherente aceptada en
   silencio. Resolverlo es una decisión de negocio, no algo que un job deba
   improvisar.
6. Cómo se respalda y se restaura el libro, y cada cuánto se prueba la
   restauración.
7. Con qué frecuencia se reconcilia contra la AEAT y quién lee el informe.

## Si algo de aquí no te cuadra

Este documento es tan bueno como lo que hay contrastado detrás, y
[doc/FUENTES.md](doc/FUENTES.md) dice explícitamente qué está comprobado contra
el servicio real y qué sigue siendo una suposición razonable. Si encuentras una
afirmación que no se sostiene, es un fallo del documento y merece un issue igual
que un fallo del código.
