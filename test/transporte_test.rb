require 'tmpdir'
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'support/pki'
require_relative 'support/esquema'
require_relative '../lib/verifactu-rails'

class CertificadoTest < Minitest::Test
  def setup
    @ca_cert, @ca_key = PKI.ca
  end

  def test_carga_desde_pkcs12
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL/O=ACME SL/serialNumber=B12345678')
    p12 = PKI.pkcs12(cert, key, 'secreto')

    certificado = VerifactuRails::Certificado.desde_pkcs12(p12, 'secreto')
    assert_equal 'ACME SL', certificado.sujeto['CN']
    assert_equal 'B12345678', certificado.sujeto['serialNumber']
  end

  def test_password_incorrecta_da_error_legible
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL')
    p12 = PKI.pkcs12(cert, key, 'secreto')

    error = assert_raises(VerifactuRails::CertificadoError) do
      VerifactuRails::Certificado.desde_pkcs12(p12, 'incorrecta')
    end
    assert_match(/contraseña incorrecta o fichero corrupto/, error.message)
  end

  def test_rechaza_certificado_caducado
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL',
                                              not_before: Time.now - (400 * 86_400),
                                              not_after: Time.now - 86_400)
    p12 = PKI.pkcs12(cert, key, 'x')
    error = assert_raises(VerifactuRails::CertificadoError) { VerifactuRails::Certificado.desde_pkcs12(p12, 'x') }
    assert_match(/caducado/, error.message)
  end

  def test_avisa_de_caducidad_proxima
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL',
                                              not_after: Time.now + (10 * 86_400))
    certificado = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(cert, key, 'x'), 'x')
    assert certificado.caduca_pronto?
    assert_in_delta 10, certificado.dias_para_caducar, 1
  end

  def test_no_avisa_si_queda_mucho
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL')
    certificado = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(cert, key, 'x'), 'x')
    refute certificado.caduca_pronto?
  end

  def test_detecta_certificado_de_sello
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=SELLO ELECTRONICO ACME SL/O=ACME SL')
    certificado = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(cert, key, 'x'), 'x')
    assert certificado.sello?
  end

  def test_representante_no_se_marca_como_sello
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=JUAN PEREZ - 12345678Z/O=ACME SL')
    certificado = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(cert, key, 'x'), 'x')
    refute certificado.sello?
  end

  def test_datos_vacios
    # Con solo comprobar la clase, este test pasaba aunque se borrara la guarda:
    # OpenSSL lanza PKCS12Error y el rescue lo convierte en el mismo
    # CertificadoError, pero con el mensaje engañoso de "contraseña incorrecta".
    ['', nil].each do |vacio|
      error = assert_raises(VerifactuRails::CertificadoError) do
        VerifactuRails::Certificado.desde_pkcs12(vacio, 'x')
      end
      assert_match(/vacíos/, error.message, "#{vacio.inspect} debe dar el error de datos vacíos")
    end
  end
end

class EndpointTest < Minitest::Test
  def setup
    ca_cert, ca_key = PKI.ca
    cert, key = PKI.emitir(ca_cert, ca_key, subject: '/CN=ACME SL')
    @cert = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(cert, key, 'x'), 'x')
  end

  def test_pruebas_normal
    t = VerifactuRails::Transporte.new(certificado: @cert, entorno: :pruebas, sello: false)
    assert_equal 'prewww1.aeat.es', URI.parse(t.url).host
  end

  def test_pruebas_sello_usa_host_distinto
    t = VerifactuRails::Transporte.new(certificado: @cert, entorno: :pruebas, sello: true)
    assert_equal 'prewww10.aeat.es', URI.parse(t.url).host
  end

  def test_produccion_normal_y_sello
    normal = VerifactuRails::Transporte.new(certificado: @cert, entorno: :produccion, sello: false)
    sello  = VerifactuRails::Transporte.new(certificado: @cert, entorno: :produccion, sello: true)
    assert_equal 'www1.agenciatributaria.gob.es', URI.parse(normal.url).host
    assert_equal 'www10.agenciatributaria.gob.es', URI.parse(sello.url).host
    refute_equal normal.url, sello.url
  end

  def test_sello_se_deduce_del_certificado
    ca_cert, ca_key = PKI.ca
    c, k = PKI.emitir(ca_cert, ca_key, subject: '/CN=SELLO ELECTRONICO ACME/O=ACME SL')
    certificado = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(c, k, 'x'), 'x')
    assert VerifactuRails::Transporte.new(certificado: certificado, entorno: :pruebas).sello?
  end

  def test_entorno_invalido
    assert_raises(ArgumentError) { VerifactuRails::Transporte.new(certificado: @cert, entorno: :staging) }
  end

  def test_por_defecto_apunta_a_pruebas
    assert_includes VerifactuRails::Transporte.new(certificado: @cert).url, 'prewww'
  end
end

# La prueba que importa: handshake mTLS completo contra un servidor real.
class TransporteMTLSTest < Minitest::Test
  def setup
    @ca_cert, @ca_key = PKI.ca
    srv_cert, srv_key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=localhost',
                                                      san: 'DNS:localhost,IP:127.0.0.1')
    @ca_file = File.join(Dir.tmpdir, "ca-#{Process.pid}.pem")
    File.write(@ca_file, @ca_cert.to_pem)

    @servidor = ServidorMTLS.new(ca_cert: @ca_cert, server_cert: srv_cert, server_key: srv_key,
                                 respuesta: '<RespuestaSuministro>OK</RespuestaSuministro>').arrancar
  end

  def teardown
    @servidor.parar
    File.delete(@ca_file) if File.exist?(@ca_file)
  end

  def test_handshake_mtls_y_entrega_del_xml
    transporte = transporte_local(cliente_valido)
    resultado = transporte.enviar('<RegFactuSistemaFacturacion>...</RegFactuSistemaFacturacion>')

    assert_equal 200, resultado[:codigo]
    assert_includes resultado[:cuerpo], 'RespuestaSuministro'

    peticion = @servidor.peticiones.first
    refute_nil peticion, 'el servidor no recibió la petición'
    # El servidor vio el certificado de cliente: mTLS efectivo, no solo TLS.
    assert_equal 'ACME SL', peticion[:cn_cliente]
    assert_equal 'text/xml; charset=utf-8', peticion[:cabeceras]['content-type']
    assert_includes peticion[:cuerpo], 'RegFactuSistemaFacturacion'
    assert_includes peticion[:cuerpo], 'soapenv:Envelope'
  end

  def test_certificado_de_otra_ca_es_rechazado
    otra_ca_cert, otra_ca_key = PKI.ca(cn: 'CA Impostora')
    c, k = PKI.emitir(otra_ca_cert, otra_ca_key, subject: '/CN=IMPOSTOR SL')
    intruso = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(c, k, 'x'), 'x')

    assert_raises(VerifactuRails::TransporteError) do
      transporte_local(intruso).enviar('<x/>')
    end
    assert_empty @servidor.peticiones
  end

  def test_ca_desconocida_da_mensaje_util
    transporte = VerifactuRails::Transporte.new(
      certificado: cliente_valido, entorno: :pruebas,
      url: "https://localhost:#{@servidor.puerto}/" # sin ca_file
    )
    error = assert_raises(VerifactuRails::TransporteError) { transporte.enviar('<x/>') }
    assert_match(/No uses VERIFY_NONE/, error.message)
  end

  def test_el_sobre_soap_es_valido
    transporte = transporte_local(cliente_valido)
    sobre = transporte.envolver('<Cabecera/>')
    assert_includes sobre, 'http://schemas.xmlsoap.org/soap/envelope/'
    assert_includes sobre, '<soapenv:Body><Cabecera/></soapenv:Body>'
  end

  # Este test existe por un fallo REAL en el primer envío a preproducción.
  #
  # El de arriba envolvía '<Cabecera/>', un relleno sin declaración XML, así que
  # pasaba en verde. Pero Envio#to_xml SÍ emite su <?xml?>, y una declaración
  # solo puede ir al principio del documento: el sobre real salía mal formado con
  # dos declaraciones. La AEAT respondió "Codigo[102].Error interno en el
  # servidor", que no dice nada porque el fallo era de parseo, no de validación.
  #
  # La lección: el payload del test tiene que ser el de verdad, no un stub.
  def test_el_sobre_con_un_envio_real_esta_bien_formado
    xml = VerifactuRails::Envio.new(
      nif_obligado: 'B12345678', nombre_obligado: 'ACME SL',
      entradas: [[registro_de_prueba, nil]]
    ).to_xml
    sobre = transporte_local(cliente_valido).envolver(xml)

    assert_equal 1, sobre.scan('<?xml').size, 'solo puede haber UNA declaración XML'

    doc = Nokogiri::XML(sobre) { |c| c.strict }
    refute_predicate doc, :nil?

    # Y lo que va dentro del Body sigue siendo el documento que valida el XSD.
    cuerpo = doc.at_xpath('//soapenv:Body/*', 'soapenv' => VerifactuRails::Transporte::SOAP_NS)
    assert_equal 'RegFactuSistemaFacturacion', cuerpo.name
    assert_empty Esquema.errores(cuerpo.to_xml)
  end

  private

  def cliente_valido
    @cliente_valido ||= begin
      c, k = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL/O=ACME SL')
      VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(c, k, 'x'), 'x')
    end
  end

  def registro_de_prueba
    sistema = VerifactuRails::SistemaInformatico.new(
      nombre_razon: 'ACME SL', nif: 'B12345678', nombre_sistema: 'X',
      id_sistema: '01', version: '1', numero_instalacion: '1'
    )
    VerifactuRails::RegistroAlta.new(
      id_emisor: 'B12345678', num_serie: 'FA/1', fecha_expedicion: Date.today,
      nombre_razon_emisor: 'ACME SL', tipo_factura: 'F1',
      descripcion_operacion: 'Prueba',
      desglose: [VerifactuRails::Detalle.new(
        base_imponible: BigDecimal('100.00'), calificacion: 'S1',
        tipo_impositivo: BigDecimal('21'), cuota_repercutida: BigDecimal('21.00')
      )],
      cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
      sistema_informatico: sistema, fecha_hora_gen: Time.now,
      destinatarios: [VerifactuRails::Destinatario.new(nombre_razon: 'Cliente SL',
                                                       nif: 'B87654321')]
    )
  end

  def transporte_local(certificado)
    VerifactuRails::Transporte.new(certificado: certificado, entorno: :pruebas,
                              url: "https://localhost:#{@servidor.puerto}/",
                              ca_file: @ca_file, timeout: 5)
  end
end
