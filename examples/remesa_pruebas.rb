# frozen_string_literal: true

# La capa Rails completa contra el entorno de PRUEBAS de la AEAT.
#
#   VF_P12=/ruta/cert.p12 VF_PASS=xxxx ruby -Ilib examples/remesa_pruebas.rb
#
# `campana_pruebas.rb` probó el PROTOCOLO construyendo los registros a mano.
# Esto prueba el CÓDIGO que se va a usar de verdad: anotar bajo lock, guardar el
# fragmento XML, generar el QR y remitir por lotes leyendo de la base de datos.
# Son cosas distintas y hasta ahora solo la primera había tocado el servicio.
#
# Necesita base de datos: se usa VF_DATABASE_URL o DATABASE_URL, y si no
# PostgreSQL local en verifactu_rails_test. Crea sus tablas si no existen.
#
# VF_SIMULACRO=1 monta todo y valida el XML contra los XSD sin abrir conexión con
# la AEAT. Sirve para comprobar que el guion funciona antes de gastar envíos; la
# base de datos sí hace falta igual.
#
# AVISO: preproducción es para pruebas PUNTUALES. Esto son dos envíos.

require 'active_record'
require_relative '../lib/verifactu_rails/libro'

SIMULACRO = !ENV['VF_SIMULACRO'].nil?

def env!(nombre)
  ENV[nombre] || abort("Falta la variable #{nombre}. Ver la cabecera de este fichero.")
end

include VerifactuRails

# --- Base de datos ----------------------------------------------------------

url = ENV['VF_DATABASE_URL'] || ENV['DATABASE_URL'] ||
      'postgresql://localhost/verifactu_rails_test'
ActiveRecord::Base.establish_connection(url)
begin
  ActiveRecord::Base.connection.execute('select 1')
rescue StandardError => e
  abort "No se pudo conectar a #{url}: #{e.message.lines.first}"
end

unless ActiveRecord::Base.connection.table_exists?(:verifactu_registros)
  ActiveRecord::Migration.verbose = false
  Libro::Migracion.new.migrate(:up)
  puts 'Tablas creadas.'
end
puts "Base de datos: #{url}"

# --- Certificado y configuración -------------------------------------------

certificado =
  unless SIMULACRO
    Certificado.desde_pkcs12(File.binread(env!('VF_P12')), env!('VF_PASS')).tap do |c|
      puts "Certificado: #{c.resumen}"
    end
  end

nif = ENV['VF_NIF'] || certificado&.nif || abort('Pasa VF_NIF.')
nombre = ENV['VF_NOMBRE'] || certificado&.titular || abort('Pasa VF_NOMBRE.')
puts "Obligado: #{nif} / #{nombre}"

Libro.configure do |c|
  c.productor_nombre = ENV['VF_PRODUCTOR'] || nombre
  c.productor_nif    = ENV['VF_PRODUCTOR_NIF'] || nif
  c.nombre_sistema   = ENV['VF_SISTEMA'] || 'PruebaVerifactuRails'
  c.id_sistema       = ENV['VF_ID_SISTEMA'] || '01'
  c.version          = VerifactuRails::VERSION
  c.entorno          = (ENV['VF_ENTORNO'] || 'pruebas').to_sym
  # Las anomalías del art. 7.i no interrumpen la facturación, pero tienen que
  # verse. En una app esto iría al log o a Sentry.
  c.al_detectar_anomalia = ->(a, r) { puts "  ANOMALÍA en #{r.num_serie}: #{a.join(', ')}" }
end

# Instalación nueva en cada ejecución: cadena limpia, y así el primer registro es
# legítimamente PrimerRegistro="S". No se autogenera dentro de la gema a
# propósito; aquí es el guion quien decide, que es como debe ser.
marca = Time.now.strftime('%Y%m%d%H%M%S')
cadena = Libro::Cadena.abrir!(numero_instalacion: ENV['VF_INSTALACION'] || "REMESA-#{marca}",
                              nif_obligado: nif, nombre_obligado: nombre)
puts "Cadena nueva: instalación #{cadena.numero_instalacion}"

# --- Anotar -----------------------------------------------------------------

serie_base = "REM/#{marca}"

registros = %w[1 2].map do |sufijo|
  cadena.anotar_alta!(
    id_emisor: nif, num_serie: "#{serie_base}/#{sufijo}", fecha_expedicion: Date.today,
    nombre_razon_emisor: nombre, tipo_factura: 'F1',
    descripcion_operacion: 'Prueba de la capa Rails',
    desglose: [Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: 'S1',
                           tipo_impositivo: BigDecimal('21'),
                           cuota_repercutida: BigDecimal('21.00'))],
    cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
    fecha_hora_gen: Time.now,
    destinatarios: [Destinatario.new(nombre_razon: ENV['VF_CLIENTE_NOMBRE'] || nombre,
                                     nif: ENV['VF_CLIENTE_NIF'] || nif)]
  )
end

puts "\n=== Anotados #{registros.size} registros ==="
registros.each do |r|
  enlace = r.primero? ? 'PRIMERO' : "tras #{r.huella_anterior[0, 16]}…"
  puts "  #{r.num_serie}  #{r.huella[0, 16]}…  #{enlace}  estado=#{r.estado}"
  puts "     QR: #{r.qr_url}"
end

# --- Remitir ----------------------------------------------------------------

# En simulacro se valida contra el XSD lo que se habría enviado, sin abrir nada.
class TransporteSimulado
  def enviar(xml)
    ruta = File.expand_path('../lib/verifactu_rails/schemas/SuministroLR.xsd', __dir__)
    esquema = Nokogiri::XML::Schema.from_document(Nokogiri::XML(File.read(ruta), ruta))
    errores = esquema.validate(Nokogiri::XML(xml))
    abort "SIMULACRO: XML inválido\n#{errores.map(&:message).join("\n")}" unless errores.empty?
    puts '  SIMULACRO: XML válido contra SuministroLR.xsd; no se envía nada.'
    exit 0
  end
end

transporte =
  if SIMULACRO
    ENV['XML_CATALOG_FILES'] ||=
      File.expand_path('../lib/verifactu_rails/schemas/catalog.xml', __dir__)
    TransporteSimulado.new
  else
    Transporte.new(certificado: certificado, entorno: Libro.configuracion.entorno,
                   sello: ENV['VF_SELLO'])
  end

puts "\n=== Remesa ==="
resultado = Libro::Remesa.new(cadena, transporte: transporte).enviar!
puts "  Estado: #{resultado.estado}"

if resultado.enviado?
  respuesta = resultado.respuesta
  puts "  #{respuesta}"
  puts "  CSV: #{respuesta.csv}"
  respuesta.lineas.each { |l| puts "    #{l}" }
end

puts "\n=== Estado en el libro ==="
cadena.registros.order(:id).each do |r|
  puts "  #{r.num_serie}  estado=#{r.estado}  csv=#{r.csv}  #{r.descripcion_error}"
end

# Una segunda remesa no debe mandar nada: o la espera sigue viva, o ya no queda
# nada pendiente. Es la comprobación de que el control de flujo funciona.
puts "\n=== Segunda remesa (no debería enviar) ==="
puts "  Estado: #{Libro::Remesa.new(cadena.reload, transporte: transporte).enviar!.estado}"
puts "  no_enviar_antes_de: #{cadena.no_enviar_antes_de}"
