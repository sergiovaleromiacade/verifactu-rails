# frozen_string_literal: true

# Consulta de lo que la AEAT tiene REALMENTE anotado, contra el entorno de
# pruebas.
#
#   VF_P12=/ruta/cert.p12 VF_PASS=xxxx VF_DIARIO=campana-CAMP-....jsonl \
#     ruby -Ilib examples/consulta_pruebas.rb
#
# Sin diario, basta con VF_INSTALACION para filtrar por ese SIF virtual.
#
# Por qué existe este guion: la respuesta al ENVÍO solo dice si la AEAT aceptó
# el registro. No dice qué guardó. Y hay al menos tres cosas que solo se pueden
# comprobar desde aquí:
#
#   1. Si una anulación surtió efecto. "Anulado" es un estado que la respuesta
#      de suministro ni siquiera sabe expresar.
#   2. Si una subsanación sustituyó al registro original o convive con él.
#   3. Si la cadena quedó como creíamos. La AEAT no valida al recibir que el
#      RegistroAnterior sea el último anotado -acepta una bifurcación sin
#      avisar-, así que reconstruirla desde lo almacenado es la ÚNICA forma de
#      detectar una cadena rota.
#
# Consultar es de solo lectura: no crea registros, no toca la cadena y no gasta
# envíos. Aun así, preproducción es para pruebas puntuales.

require 'json'
require 'verifactu-rails'
include VerifactuRails

def env!(nombre)
  ENV[nombre] || abort("Falta la variable #{nombre}. Ver la cabecera de este fichero.")
end

certificado = Certificado.desde_pkcs12(File.binread(env!('VF_P12')), env!('VF_PASS'))
nif = ENV['VF_NIF'] || certificado.nif || abort('Pasa VF_NIF.')
nombre = ENV['VF_NOMBRE'] || certificado.titular || abort('Pasa VF_NOMBRE.')
puts "Obligado: #{nif} / #{nombre}"

# --- De dónde salen la instalación y las huellas esperadas ------------------

diario = ENV['VF_DIARIO']
cabecera = nil
esperadas = {}

if diario
  registros = File.readlines(diario).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
  cabecera = registros.find { |r| r['tipo'] == 'cabecera' } ||
             abort("#{diario} no tiene cabecera.")
  # El diario solo guarda el ÚLTIMO registro de cada envío, así que del lote de
  # tres solo consta el tercero. Se contrasta lo que hay.
  registros.select { |r| r['tipo'] == 'fase' }.each do |r|
    esperadas[r['eslabon']['num_serie']] = r['eslabon']['huella']
  end
  puts "Diario: #{diario} (#{esperadas.size} huellas que contrastar)"
end

# El mensaje distingue los dos casos a propósito: "pasa VF_INSTALACION o
# VF_DIARIO" es inútil cuando SÍ pasaste el diario y lo que falla es su
# contenido, porque manda a mirar al sitio equivocado.
instalacion = ENV['VF_INSTALACION'] || cabecera&.dig('instalacion')
if instalacion.nil?
  abort(if diario
          "#{diario} no trae 'instalacion' en su cabecera. Pásala a mano con VF_INSTALACION."
        else
          'No sé qué SIF consultar: pon VF_DIARIO=<fichero de la campaña> o ' \
            'VF_INSTALACION=<NumeroInstalacion>. Ninguna de las dos está en el entorno.'
        end)
end

fecha_ref = cabecera ? Date.strptime(cabecera.fetch('fecha'), '%d-%m-%Y') : Date.today
ejercicio = ENV['VF_EJERCICIO'] || fecha_ref.year.to_s
periodo   = ENV['VF_PERIODO'] || format('%<mes>02d', mes: fecha_ref.month)
puts "Periodo: #{ejercicio}-#{periodo}, instalación #{instalacion}"

# El filtro por SIF es lo que aísla una cadena concreta cuando cada fuente de
# facturación lleva su propio NumeroInstalacion. La semántica exacta del cotejo
# (si compara todos los campos o solo algunos) no consta en las fuentes que
# manejamos, así que si esto devuelve SinDatos, prueba con VF_SIN_FILTRO_SIF=1.
sistema =
  unless ENV['VF_SIN_FILTRO_SIF']
    SistemaInformatico.new(
      nombre_razon: ENV['VF_PRODUCTOR'] || nombre,
      nif: ENV['VF_PRODUCTOR_NIF'] || nif,
      nombre_sistema: ENV['VF_SISTEMA'] || 'PruebaVerifactuRails',
      id_sistema: ENV['VF_ID_SISTEMA'] || '01',
      version: VerifactuRails::VERSION,
      numero_instalacion: instalacion
    )
  end

# --- Consulta, paginando ----------------------------------------------------

transporte = Transporte.new(certificado: certificado,
                            entorno: (ENV['VF_ENTORNO'] || 'pruebas').to_sym,
                            sello: ENV['VF_SELLO'])

anotados = []
clave = nil
pagina = 0

loop do
  pagina += 1
  consulta = Consulta.new(nif_obligado: nif, nombre_obligado: nombre,
                          ejercicio: ejercicio, periodo: periodo,
                          sistema_informatico: sistema, clave_paginacion: clave)
  resultado = transporte.enviar(consulta.to_xml)
  respuesta = RespuestaConsulta.new(resultado[:cuerpo])
  puts "\nPágina #{pagina}: HTTP #{resultado[:codigo]} -> #{respuesta}"
  anotados.concat(respuesta.registros)

  break unless respuesta.hay_mas_paginas?

  clave = respuesta.clave_paginacion
  break if clave.nil? # defensa: paginación "S" sin clave dejaría un bucle infinito
end

if anotados.empty?
  abort "\nSinDatos. Si esperabas registros, prueba con VF_SIN_FILTRO_SIF=1: puede " \
        'ser que el cotejo del SIF no funcione como suponemos.'
end

# --- Lo que la AEAT tiene guardado ------------------------------------------

puts "\n=== #{anotados.size} registros anotados ==="
anotados.each do |r|
  enlace = r.primer_registro? ? 'PRIMERO' : "tras #{r.num_serie_anterior}"
  puts "  #{r.num_serie}  #{r.estado}#{r.subsanacion? ? ' (subsanación)' : ''}  #{enlace}"
  puts "     huella #{r.huella}  total #{r.importe_total}  mod. #{r.timestamp_modificacion}"
  puts "     [#{r.codigo_error}] #{r.descripcion_error}" if r.codigo_error
end

# --- Cotejo con lo que creíamos haber mandado -------------------------------

unless esperadas.empty?
  puts "\n=== Cotejo contra el diario ==="
  esperadas.each do |serie, huella|
    guardados = anotados.select { |r| r.num_serie == serie }
    if guardados.empty?
      puts "  #{serie}: NO APARECE en lo anotado"
    elsif guardados.any? { |r| r.huella == huella }
      puts "  #{serie}: la huella coincide con la que enviamos"
    else
      puts "  #{serie}: HUELLA DISTINTA"
      puts "     enviada: #{huella}"
      guardados.each { |r| puts "     anotada: #{r.huella}" }
    end
  end
end

# --- La cadena, reconstruida desde lo almacenado ----------------------------
#
# Esto es lo que no se puede saber al enviar. Se agrupa por el eslabón al que
# apunta cada registro: si dos apuntan al mismo, la cadena está bifurcada, y la
# AEAT no lo habría dicho.

puts "\n=== La cadena tal y como la guardó la AEAT ==="
por_huella = anotados.group_by(&:huella)
duplicadas = por_huella.select { |h, rs| h && rs.size > 1 }
puts "  AVISO: #{duplicadas.size} huellas repetidas entre registros distintos" unless duplicadas.empty?

primeros = anotados.select(&:primer_registro?)
puts "  Registros marcados PrimerRegistro: #{primeros.size} (#{primeros.map(&:num_serie).join(', ')})"
puts '  AVISO: más de un PrimerRegistro en la misma cadena' if primeros.size > 1

anotados.reject(&:primer_registro?).group_by(&:huella_anterior).each do |huella, hijos|
  padre = por_huella[huella]&.first
  origen = padre ? padre.num_serie : "un registro que no sale en esta consulta (#{huella.to_s[0, 16]}…)"
  next puts "  #{hijos.first.num_serie} <- #{origen}" if hijos.size == 1

  puts "  CADENA BIFURCADA: #{hijos.map(&:num_serie).join(' y ')} apuntan los dos a #{origen}"
end

huerfanos = anotados.reject(&:primer_registro?)
                    .reject { |r| por_huella.key?(r.huella_anterior) }
unless huerfanos.empty?
  puts "\n  #{huerfanos.size} registro(s) apuntan a un eslabón que no está en esta consulta."
  puts '  OJO antes de alarmarse: la consulta devuelve UNA FILA POR FACTURA con su'
  puts '  estado actual, no el histórico de registros. Si una factura se subsanó o se'
  puts '  anuló, su alta original ya no se devuelve, y todo lo que encadenaba tras ella'
  puts '  aparece aquí aunque la cadena esté perfecta. También pasa si la cadena empezó'
  puts '  en otro periodo. Solo es un síntoma real si la huella no la reconoces.'
end
