import sys
from awsglue.utils import getResolvedOptions

# Get job parameters
args = getResolvedOptions(sys.argv, ['LIBRARY_PATH'])

sys.path.append(args['LIBRARY_PATH'])
from library.print_util import imprimir

imprimir("hello world with glue!")