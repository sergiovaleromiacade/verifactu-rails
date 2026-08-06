# frozen_string_literal: true

require 'openssl'
require 'socket'

# Fábrica de material criptográfico de prueba. Nos permite ejercitar todo el
# camino mTLS sin depender de un certificado real de la FNMT.
module PKI
  # Generar RSA-2048 cuesta ~0,5 s. Una suite que tarda 10 s deja de ejecutarse
  # en cada guardado, así que reutilizamos un pool de claves: no afecta a lo que
  # estamos verificando (handshake y validación), solo al coste.
  POOL = Array.new(4) { OpenSSL::PKey::RSA.new(2048) }.freeze

  def self.clave = POOL.sample

  def self.ca(cn: 'CA de Pruebas Verifactu')
    key = clave
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{cn}")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + (365 * 86_400)
    ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(ef.create_extension('basicConstraints', 'CA:TRUE', true))
    cert.add_extension(ef.create_extension('keyUsage', 'keyCertSign,cRLSign', true))
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    [cert, key]
  end

  # @param not_after [Time] permite fabricar certificados ya caducados
  def self.emitir(ca_cert, ca_key, subject:, not_after: Time.now + (365 * 86_400),
                  not_before: Time.now - 3600, san: nil)
    key = clave
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(2..1_000_000)
    cert.subject = OpenSSL::X509::Name.parse(subject)
    cert.issuer = ca_cert.subject
    cert.public_key = key.public_key
    cert.not_before = not_before
    cert.not_after = not_after
    ef = OpenSSL::X509::ExtensionFactory.new(ca_cert, cert)
    cert.add_extension(ef.create_extension('basicConstraints', 'CA:FALSE', true))
    cert.add_extension(ef.create_extension('subjectAltName', san)) if san
    cert.sign(ca_key, OpenSSL::Digest.new('SHA256'))
    [cert, key]
  end

  def self.pkcs12(cert, key, password, ca: [])
    OpenSSL::PKCS12.create(password, 'verifactu-test', key, cert, ca).to_der
  end
end

# Servidor TLS mínimo que EXIGE certificado de cliente. Si el cliente no lo
# presenta o no está firmado por nuestra CA, el handshake falla: justo lo que
# queremos poder demostrar.
class ServidorMTLS
  attr_reader :puerto, :peticiones

  def initialize(ca_cert:, server_cert:, server_key:, respuesta: '<ok/>')
    @peticiones = []
    @respuesta = respuesta
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = server_cert
    ctx.key = server_key
    ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
    ctx.cert_store = OpenSSL::X509::Store.new.tap { |s| s.add_cert(ca_cert) }

    @tcp = TCPServer.new('127.0.0.1', 0)
    @puerto = @tcp.addr[1]
    @ssl = OpenSSL::SSL::SSLServer.new(@tcp, ctx)
    @ssl.start_immediately = true
  end

  def arrancar
    @hilo = Thread.new do
      loop do
        conexion = @ssl.accept
        atender(conexion)
      rescue OpenSSL::SSL::SSLError, IOError, Errno::ECONNRESET
        next # handshake rechazado: es un resultado válido de la prueba
      end
    end
    self
  end

  def parar
    @hilo&.kill
    @ssl.close rescue nil
  end

  private

  def atender(conexion)
    linea = conexion.gets.to_s
    cabeceras = {}
    while (l = conexion.gets) && l.strip != ''
      k, v = l.split(':', 2)
      cabeceras[k.to_s.downcase.strip] = v.to_s.strip
    end
    cuerpo = conexion.read(cabeceras['content-length'].to_i)

    @peticiones << {
      linea: linea.strip,
      cabeceras: cabeceras,
      cuerpo: cuerpo,
      cn_cliente: conexion.peer_cert&.subject&.to_a&.find { |k, _, _| k == 'CN' }&.at(1)
    }

    conexion.print "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\n" \
                   "Content-Length: #{@respuesta.bytesize}\r\n\r\n#{@respuesta}"
    conexion.close
  end
end
