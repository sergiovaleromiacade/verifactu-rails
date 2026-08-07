# frozen_string_literal: true

# Campaña de pruebas contra el entorno de PRUEBAS de la AEAT (prewww1/prewww10).
#
#   VF_P12=/ruta/cert.p12 VF_PASS=xxxx ruby -Ilib examples/campana_pruebas.rb
#
# `envio_pruebas.rb` manda UN alta y sirve para el primer contacto. Esto cubre lo
# que aquel guion deja sin tocar contra el servicio real: lotes de más de un
# registro, anulaciones, rectificativas y subsanación. Son cuatro envíos:
#
#   1. lote          3 altas F1 encadenadas ENTRE SÍ dentro de un mismo envío
#   2. anulacion     anula la tercera del lote
#   3. rectificativa R1 sustitutiva de la segunda, con ImporteRectificacion
#   4. subsanacion   reenvía la primera con Subsanacion="S" y otros importes
#
# AVISO: preproducción es para pruebas PUNTUALES; la AEAT advierte que un uso
# masivo puede acabar en bloqueo de acceso. Esta campaña son 4 peticiones y
# respeta el TiempoEsperaEnvio que devuelve la AEAT entre una y otra, así que
# tarda varios minutos. No la pongas en un bucle.
#
# CADENA LIMPIA. Cada ejecución usa un NumeroInstalacion nuevo, que la AEAT
# considera un "SIF virtual" independiente (FAQs Desarrolladores v1.3): así el
# primer registro es legítimamente PrimerRegistro="S" y no hay que saber cuál
# fue el último eslabón de una ejecución anterior. Fijar VF_INSTALACION a mano
# rompe eso: la AEAT lo aceptaría, pero con error admisible y obligación de
# subsanar (Validaciones ap. 4.3.1).
#
# DIARIO Y REANUDACIÓN. Cada envío se anota en un JSONL antes de seguir. Si la
# campaña se corta a medias, relánzala con VF_DIARIO apuntando a ese fichero y
# retoma en la fase que quedó pendiente, sobre la misma cadena. Sin esto, un
# corte en la fase 3 obliga a empezar de cero y a gastar cuatro envíos más.

#
# ENSAYO EN SECO. Con VF_SIMULACRO=1 no se abre ninguna conexión: se construyen
# las cuatro fases y se validan contra los XSD oficiales. Sirve para comprobar
# que la campaña entera se monta antes de gastar envíos, que es lo que hace caro
# equivocarse aquí. No necesita certificado, pero sí VF_NIF y VF_NOMBRE.

require 'json'

SIMULACRO = !ENV['VF_SIMULACRO'].nil?

# libxml2 lee esta variable al inicializar el catálogo, y lo hace al cargar
# nokogiri: por eso va antes del require. Es lo que resuelve el import de
# xmldsig sin salir a la red. La pone este guion, nunca la librería
# (ver schemas/PROCEDENCIA.md).
if SIMULACRO
  ENV['XML_CATALOG_FILES'] ||= File.expand_path('../lib/verifactu_rails/schemas/catalog.xml', __dir__)
end

require 'verifactu-rails'
include VerifactuRails

def env!(nombre)
  ENV[nombre] || abort("Falta la variable #{nombre}. Ver la cabecera de este fichero.")
end

FASES = %w[lote anulacion rectificativa subsanacion].freeze

# --- Certificado y obligado -------------------------------------------------

certificado =
  if SIMULACRO
    puts 'SIMULACRO: no se abre ninguna conexión, se valida contra los XSD.'
    nil
  else
    Certificado.desde_pkcs12(File.binread(env!('VF_P12')), env!('VF_PASS')).tap do |c|
      puts "Certificado: #{c.resumen}"
      puts "  caduca en #{c.dias_para_caducar} días" if c.caduca_pronto?
    end
  end

# El par NIF + NombreRazon se toma del certificado: es la única combinación de la
# que se sabe seguro que está en el censo. Un nombre que no cuadre da un 4104 que
# habla del NIF y despista.
nif = ENV['VF_NIF'] || certificado&.nif || abort('No se pudo leer el NIF del certificado: pasa VF_NIF.')
nombre = ENV['VF_NOMBRE'] || certificado&.titular || abort('No se pudo leer el titular: pasa VF_NOMBRE.')
puts "  Obligado: #{nif} / #{nombre}"

if certificado&.nif && certificado.nif != nif
  abort "  EL NIF NO COINCIDE con el del certificado (#{certificado.nif}). La AEAT dará 4104."
end
if certificado&.titular && certificado.titular.casecmp(nombre) != 0
  puts "  AVISO: el nombre difiere del certificado (#{certificado.titular}). Si sale un 4104, es por aquí."
end

# --- Diario: cabecera nueva o reanudación -----------------------------------

diario = ENV['VF_DIARIO']
hechas = {}

if diario && File.exist?(diario)
  registros = File.readlines(diario).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
  cabecera = registros.find { |r| r['tipo'] == 'cabecera' } ||
             abort("#{diario} no tiene línea de cabecera: no se puede reanudar.")
  registros.select { |r| r['tipo'] == 'fase' }.each { |r| hechas[r['fase']] = r }

  instalacion = cabecera.fetch('instalacion')
  serie_base  = cabecera.fetch('serie_base')
  fecha       = cabecera.fetch('fecha')
  puts "\nReanudando #{diario}"
  puts "  instalación #{instalacion}, series #{serie_base}/*"
  puts "  ya hechas: #{hechas.keys.join(', ')}" unless hechas.empty?
else
  marca = Time.now.strftime('%Y%m%d%H%M%S')
  instalacion = ENV['VF_INSTALACION'] || "CAMP-#{marca}"
  serie_base  = ENV['VF_SERIE_BASE'] || "CAMP/#{marca}"
  fecha       = Date.today.strftime('%d-%m-%Y')
  diario ||= SIMULACRO ? nil : "campana-#{instalacion}.jsonl"
  if diario
    File.write(diario, "#{JSON.generate({ 'tipo' => 'cabecera', 'instalacion' => instalacion,
                                          'serie_base' => serie_base, 'fecha' => fecha,
                                          'nif' => nif })}\n", mode: 'a')
  end
  puts "\nCadena nueva. Diario: #{diario || '(ninguno, es un simulacro)'}"
  puts "  instalación #{instalacion} (SIF virtual propio), series #{serie_base}/*"
end

# El NumeroInstalacion no puede repetirse NUNCA, ni al reinstalar sobre la misma
# máquina (FAQs v1.3). Aquí lleva la marca temporal justo por eso.
sistema = SistemaInformatico.new(
  nombre_razon: ENV['VF_PRODUCTOR'] || nombre,
  nif: ENV['VF_PRODUCTOR_NIF'] || nif,
  nombre_sistema: ENV['VF_SISTEMA'] || 'PruebaVerifactuRails',
  id_sistema: ENV['VF_ID_SISTEMA'] || '01',
  version: VerifactuRails::VERSION,
  numero_instalacion: instalacion
)

# La AEAT valida el par NIF + NombreRazon del DESTINATARIO contra el censo (error
# 1239), así que por defecto se usa el propio titular: es el único par del que se
# sabe seguro que está censado.
destinatarios = [Destinatario.new(nombre_razon: ENV['VF_CLIENTE_NOMBRE'] || nombre,
                                 nif: ENV['VF_CLIENTE_NIF'] || nif)]

serie = ->(sufijo) { "#{serie_base}/#{sufijo}" }

def detalle(base, tipo, cuota)
  Detalle.new(base_imponible: BigDecimal(base), calificacion: 'S1',
              tipo_impositivo: BigDecimal(tipo), cuota_repercutida: BigDecimal(cuota))
end

# --- Envío y anotación ------------------------------------------------------

transporte =
  unless SIMULACRO
    Transporte.new(certificado: certificado,
                   entorno: (ENV['VF_ENTORNO'] || 'pruebas').to_sym,
                   sello: ENV['VF_SELLO'])
  end

# Solo en simulacro: la validación contra el esquema oficial sustituye al envío.
def validar_esquema(xml)
  ruta = File.expand_path('../lib/verifactu_rails/schemas/SuministroLR.xsd', __dir__)
  # Con la ruta como URL base, para que los imports relativos del XSD no se
  # busquen en el directorio de trabajo.
  esquema = Nokogiri::XML::Schema.from_document(Nokogiri::XML(File.read(ruta), ruta))
  esquema.validate(Nokogiri::XML(xml))
end

# Devuelve el RegistroAnterior que deja este envío, o aborta. Aborta a propósito
# en vez de seguir: encadenar sobre un registro que la AEAT NO anotó produciría
# una cadena que ella acepta en silencio (está comprobado que no valida el
# eslabón al recibir) y la campaña dejaría de medir lo que dice medir.
def enviar(transporte, diario, fase, nif, nombre, entradas)
  puts "\n=== Fase #{fase}: #{entradas.size} registro(s) ==="
  xml = Envio.new(nif_obligado: nif, nombre_obligado: nombre, entradas: entradas).to_xml

  # La huella que se imprime tiene que ser la que viaja dentro del XML. Con
  # `anterior` mal pasado se imprimía la huella SIN encadenar mientras se enviaba
  # la encadenada: es el peor sitio posible para una mentira, porque esto es justo
  # lo que se compara ante un rechazo por huella.
  huellas = entradas.map do |registro, anterior|
    h = registro.huella(anterior: anterior)
    abort "INCOHERENCIA: la huella de #{registro.num_serie} no viaja en el XML." unless xml.include?(">#{h}<")
    puts "  #{registro.num_serie} -> #{h[0, 16]}… (anterior: #{anterior ? anterior.num_serie : 'ninguno'})"
    h
  end

  # La comprobación anterior solo dice que la huella impresa es la que viaja; no
  # dice que la cadena esté bien enlazada. Y ese fallo NO lo detecta nadie más:
  # está comprobado que la AEAT acepta una cadena bifurcada sin avisar. Si el
  # guion se equivoca al enlazar, la campaña saldría "Correcto" sin demostrar
  # nada, que es justo el resultado que más engaña.
  entradas.each_cons(2).with_index do |((anterior_reg, _), (siguiente_reg, enlace)), i|
    next if enlace && enlace.huella == huellas[i] && enlace.num_serie == anterior_reg.num_serie

    abort "CADENA ROTA dentro del lote: #{siguiente_reg.num_serie} debería " \
          "encadenar tras #{anterior_reg.num_serie}, y apunta a " \
          "#{enlace ? enlace.num_serie : 'ninguno'}."
  end

  ultimo = entradas.last.first
  eslabon = { 'num_serie' => ultimo.num_serie, 'fecha_expedicion' => ultimo.fecha_expedicion,
              'huella' => huellas.last, 'id_emisor' => ultimo.id_emisor }

  if transporte.nil?
    errores = validar_esquema(xml)
    if errores.empty?
      puts '  SIMULACRO: XML válido contra SuministroLR.xsd'
    else
      puts '  SIMULACRO: XML INVÁLIDO'
      errores.each { |e| puts "    #{e.message}" }
      abort
    end
    return [eslabon, 0]
  end

  resultado = transporte.enviar(xml)
  puts "  HTTP #{resultado[:codigo]}"
  respuesta = Respuesta.new(resultado[:cuerpo])
  puts "  #{respuesta}"
  puts "  CSV: #{respuesta.csv}"
  respuesta.lineas.each { |l| puts "    #{l}" }
  unless respuesta.a_subsanar.empty?
    puts '  OJO: anotados pero OBLIGAN A SUBSANAR (no los reenvíes tal cual).'
  end

  File.write(diario, "#{JSON.generate({ 'tipo' => 'fase', 'fase' => fase,
                                        'estado_envio' => respuesta.estado_envio,
                                        'csv' => respuesta.csv,
                                        'tiempo_espera' => respuesta.tiempo_espera,
                                        # `duplicado` es otro Struct: sin aplanarlo, JSON lo
                                        # serializa como un to_s inútil para depurar después.
                                        'lineas' => respuesta.lineas.map { |l|
                                          l.to_h.merge(duplicado: l.duplicado&.to_h)
                                        },
                                        'eslabon' => eslabon })}\n", mode: 'a')

  linea_ultimo = respuesta.lineas.find { |l| l.num_serie == ultimo.num_serie }
  unless linea_ultimo&.anotado?
    abort "  El último registro del envío no quedó anotado (#{linea_ultimo || 'sin línea en la respuesta'}). " \
          "La cadena se detiene aquí; arregla la causa y reanuda con VF_DIARIO=#{diario}."
  end

  [eslabon, respuesta.tiempo_espera]
end

def a_registro_anterior(eslabon)
  RegistroAnterior.new(id_emisor: eslabon.fetch('id_emisor'),
                       num_serie: eslabon.fetch('num_serie'),
                       fecha_expedicion: eslabon.fetch('fecha_expedicion'),
                       huella: eslabon.fetch('huella'))
end

def esperar(segundos)
  return if segundos.nil? || segundos.zero?
  return puts("  (VF_SIN_ESPERA: se salta la espera de #{segundos}s)") if ENV['VF_SIN_ESPERA']

  puts "  Esperando #{segundos}s antes del siguiente envío (TiempoEsperaEnvio)…"
  sleep segundos
end

# --- Las cuatro fases -------------------------------------------------------

anterior = nil
espera = nil

FASES.each do |fase|
  if (ya = hechas[fase])
    puts "\n=== Fase #{fase}: ya hecha (#{ya['estado_envio']}), se salta ==="
    anterior = a_registro_anterior(ya.fetch('eslabon'))
    next
  end

  esperar(espera)
  ahora = Time.now

  entradas =
    case fase
    # Tres altas en UN envío, encadenadas entre sí: el eslabón de cada una es la
    # anterior del mismo lote, no el último envío. Es el caso que los tests
    # cubren en XML y que nunca se había probado contra el servicio real.
    when 'lote'
      altas = %w[1 2 3].map.with_index do |sufijo, i|
        RegistroAlta.new(
          id_emisor: nif, num_serie: serie.call(sufijo), fecha_expedicion: fecha,
          nombre_razon_emisor: nombre, tipo_factura: 'F1',
          descripcion_operacion: "Campana VERI*FACTU, alta #{i + 1} de 3",
          desglose: [detalle('100.00', '21', '21.00')],
          cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
          sistema_informatico: sistema, fecha_hora_gen: ahora + i,
          destinatarios: destinatarios
        )
      end
      pares = []
      altas.each_with_index do |alta, i|
        previo = i.zero? ? anterior : RegistroAnterior.new(
          id_emisor: altas[i - 1].id_emisor, num_serie: altas[i - 1].num_serie,
          fecha_expedicion: altas[i - 1].fecha_expedicion,
          huella: altas[i - 1].huella(anterior: pares[i - 1][1])
        )
        pares << [alta, previo]
      end
      pares

    # Se anula la tercera del lote. Su número no se podrá reutilizar: la AEAT
    # responde "Registro de facturación duplicado".
    when 'anulacion'
      [[RegistroAnulacion.new(id_emisor: nif, num_serie: serie.call('3'),
                              fecha_expedicion: fecha, sistema_informatico: sistema,
                              fecha_hora_gen: ahora),
        anterior]]

    # R1 sustitutiva de la segunda: reexpresa el importe corregido COMPLETO, así
    # que declara en ImporteRectificacion la base y la cuota que sustituye.
    when 'rectificativa'
      [[RegistroAlta.new(
        id_emisor: nif, num_serie: serie.call('R'), fecha_expedicion: fecha,
        nombre_razon_emisor: nombre, tipo_factura: 'R1', tipo_rectificativa: 'S',
        descripcion_operacion: "Rectificativa sustitutiva de #{serie.call('2')}",
        desglose: [detalle('150.00', '21', '31.50')],
        cuota_total: BigDecimal('31.50'), importe_total: BigDecimal('181.50'),
        sistema_informatico: sistema, fecha_hora_gen: ahora,
        destinatarios: destinatarios,
        facturas_rectificadas: [IdFactura.new(id_emisor: nif, num_serie: serie.call('2'),
                                              fecha_expedicion: fecha)],
        importe_rectificacion: ImporteRectificacion.new(base: BigDecimal('100.00'),
                                                        cuota: BigDecimal('21.00'))
      ), anterior]]

    # Subsanación de la PRIMERA: mismo IDFactura, importes corregidos. Es el único
    # mecanismo para arreglar un registro que la AEAT ya aceptó. RechazoPrevio="N"
    # porque no hubo rechazo: solo se corrige el contenido.
    when 'subsanacion'
      [[RegistroAlta.new(
        id_emisor: nif, num_serie: serie.call('1'), fecha_expedicion: fecha,
        nombre_razon_emisor: nombre, tipo_factura: 'F1',
        descripcion_operacion: 'Campana VERI*FACTU, alta 1 de 3 (subsanada)',
        desglose: [detalle('110.00', '21', '23.10')],
        cuota_total: BigDecimal('23.10'), importe_total: BigDecimal('133.10'),
        sistema_informatico: sistema, fecha_hora_gen: ahora,
        destinatarios: destinatarios, subsanacion: 'S', rechazo_previo: 'N'
      ), anterior]]
    end

  eslabon, espera = enviar(transporte, diario, fase, nif, nombre, entradas)
  anterior = a_registro_anterior(eslabon)
end

puts "\n=== Campaña completa ==="
puts "Diario: #{diario || '(ninguno, era un simulacro)'}"
puts 'Repasa las líneas: un EstadoEnvio "Correcto" puede contener registros'
puts 'AceptadoConErrores, que quedan anotados pero obligan a subsanar.'
