import os
from jinja2 import Environment, FileSystemLoader
from optparse import OptionParser, Option

parser = OptionParser()
parser.add_option("-t", "--template", dest="template", default="./config/cloudformation.template.jinja",
                  help="the template file to load.", metavar="FILE")
parser.add_option("-m", "--multi-availability-zones",
                  action="store_true", dest="multi_az", default=False,
                  help="generate multi availability zones")
parser.add_option("-d", "--number-of-deas",
                  action="store", type="int", dest="number_of_deas", default=1,
                  help="number of deas in each AZ")

(options, args) = parser.parse_args()
env = Environment(loader=FileSystemLoader(os.path.dirname(options.template)))
template = env.get_template(os.path.basename(options.template))
print template.render(multi_az=options.multi_az, number_of_deas=options.number_of_deas)
