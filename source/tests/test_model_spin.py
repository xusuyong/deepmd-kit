import unittest

import numpy as np
from common import DataSystem
from common import del_data
from common import gen_data
from common import j_loader

from deepmd.common import j_must_have
from deepmd.descriptor import DescrptSeA
from deepmd.env import tf
from deepmd.fit import EnerFitting
from deepmd.model import EnerModel
from deepmd.utils.spin import Spin

GLOBAL_ENER_FLOAT_PRECISION = tf.float64
GLOBAL_TF_FLOAT_PRECISION = tf.float64
GLOBAL_NP_FLOAT_PRECISION = np.float64


class TestModelSpin(tf.test.TestCase):
    def setUp(self):
        gen_data()

    def tearDown(self):
        del_data()

    def test_model_spin(self):
        jfile = "test_model_spin.json"
        jdata = j_loader(jfile)

        # set system information
        systems = j_must_have(jdata["training"]["training_data"], "systems")
        set_pfx = j_must_have(jdata["training"], "set_prefix")
        batch_size = j_must_have(jdata["training"]["training_data"], "batch_size")
        batch_size = 2
        test_size = j_must_have(jdata["training"]["validation_data"], "numb_btch")
        stop_batch = j_must_have(jdata["training"], "numb_steps")
        rcut = j_must_have(jdata["model"]["descriptor"], "rcut")
        data = DataSystem(systems, set_pfx, batch_size, test_size, rcut, run_opt=None)
        test_data = data.get_test()

        # initialize model
        descrpt_param = jdata["model"]["descriptor"]
        spin_param = jdata["model"]["spin"]
        fitting_param = jdata["model"]["fitting_net"]
        spin = Spin(**spin_param)
        descrpt_param["spin"] = spin
        descrpt = DescrptSeA(**descrpt_param, uniform_seed=True)
        fitting_param.pop("type", None)
        fitting_param["descrpt"] = descrpt
        fitting_param["spin"] = spin
        fitting = EnerFitting(**fitting_param, uniform_seed=True)
        model = EnerModel(descrpt, fitting, spin=spin)

        input_data = {
            "coord": [test_data["coord"]],
            "box": [test_data["box"]],
            "type": [test_data["type"]],
            "natoms_vec": [test_data["natoms_vec"]],
            "default_mesh": [test_data["default_mesh"]],
        }

        model._compute_input_stat(input_data)
        model.descrpt.bias_atom_e = data.compute_energy_shift()

        t_prop_c = tf.placeholder(tf.float32, [5], name="t_prop_c")
        t_energy = tf.placeholder(GLOBAL_ENER_FLOAT_PRECISION, [None], name="t_energy")
        t_coord = tf.placeholder(GLOBAL_TF_FLOAT_PRECISION, [None], name="i_coord")
        t_type = tf.placeholder(tf.int32, [None], name="i_type")
        t_natoms = tf.placeholder(tf.int32, [None], name="i_natoms")
        t_box = tf.placeholder(GLOBAL_TF_FLOAT_PRECISION, [None, 9], name="i_box")
        t_mesh = tf.placeholder(tf.int32, [None], name="i_mesh")
        is_training = tf.placeholder(tf.bool)
        t_fparam = None

        model_pred = model.build(
            t_coord,
            t_type,
            t_natoms,
            t_box,
            t_mesh,
            t_fparam,
            suffix="model_spin",
            reuse=False,
        )
        energy = model_pred["energy"]
        force = model_pred["force"]
        virial = model_pred["virial"]

        # feed data and get results
        feed_dict_test = {
            t_prop_c: test_data["prop_c"],
            t_energy: test_data["energy"],
            t_coord: np.reshape(test_data["coord"], [-1]),
            t_box: np.reshape(test_data["box"], [-1, 9]),
            t_type: np.reshape(test_data["type"], [-1]),
            t_natoms: np.array([48, 48, 16, 16, 16]),
            t_mesh: test_data["default_mesh"],
            is_training: False,
        }

        sess = self.test_session().__enter__()
        sess.run(tf.global_variables_initializer())
        [out_ener, out_force, out_virial] = sess.run(
            [energy, force, virial], feed_dict=feed_dict_test
        )

        out_ener = np.reshape(out_ener, [-1])
        natoms_real = np.sum(
            test_data["natoms_vec"][2 : 2 + len(spin_param["use_spin"])]
        )
        force_real = np.reshape(out_force[:, : natoms_real * 3], [-1])
        force_mag = np.reshape(out_force[:, natoms_real * 3 :], [-1])

        refe = [328.28031971076655, 328.28107597905125]
        refr = [
            0.0012030290336905699,
            0.0007971919783355003,
            -0.0006567961134595433,
            0.0016331880279340924,
            0.0001755705869242296,
            -0.002028278555259529,
            0.0020179733668702943,
            0.0006556599934480984,
            -0.0017117093423057138,
            0.0011674481303514212,
            0.0005798486652735385,
            -0.0010562287320020312,
            0.0003776055600004675,
            1.825785311616781e-05,
            -0.0007612020596437039,
            0.0016578269240946821,
            0.000594741081780936,
            -0.0015096274115336365,
            0.0013554232697761785,
            -0.0001451130073990949,
            -0.0026391595911377927,
            0.00120916870549262,
            -0.0008578677981125778,
            -0.0005637201200068744,
            -0.0006003718872312487,
            0.0004204801860915163,
            5.329487775035911e-05,
            -0.0008682258524621948,
            2.277747461570251e-06,
            0.0009162443887154644,
            -0.001469923820042786,
            -0.00021375159069444635,
            0.0021744309585981225,
            -0.0015071762445949505,
            -0.00016234008130729897,
            0.0011185456387647896,
            -0.0012973715541322569,
            -0.0007731688688734572,
            0.0011458799024849243,
            -0.0013435279939996584,
            -0.0007657242410277901,
            0.001852317412757997,
            -0.0018951462729415326,
            -8.549377626046895e-05,
            0.002043566992628339,
            -0.0016565733713329494,
            0.00011153598510420769,
            0.0015423855172682702,
            0.00010722735899653796,
            6.1385262827998515e-06,
            -2.4162867065148623e-05,
            -2.203235203717596e-05,
            -0.0001362776201848821,
            3.6667880058530934e-07,
            -3.25138529123782e-05,
            -5.926896028107941e-05,
            -4.786525962912144e-05,
            5.881077772899061e-05,
            4.009480924082682e-05,
            1.2879523468208221e-05,
            -0.00013413466245204217,
            -7.083527415288717e-06,
            -2.924809501181675e-06,
            8.471589796122067e-05,
            -3.516224086547101e-05,
            1.3403888439631847e-05,
            8.16497151676977e-05,
            3.246453297371882e-05,
            4.0242087225113016e-05,
            -0.00013427516555845754,
            1.7594498825285322e-05,
            -3.692301669628471e-06,
            -5.240649798867663e-06,
            -7.624498921107889e-05,
            -1.3794520886132115e-05,
            0.00013118447682948292,
            -3.610035245647602e-05,
            -2.3346650705143464e-05,
            4.7024988528016045e-05,
            -5.915081574761293e-05,
            2.5418064770908414e-05,
            -9.92873839301275e-05,
            -2.4507248632144788e-05,
            2.3874697329185306e-05,
            2.82541527989979e-05,
            3.144034844984165e-05,
            4.9075760913275926e-06,
            -5.108937315214004e-05,
            -6.916478778889123e-05,
            -5.249617469297928e-05,
            -4.9718841635238106e-05,
            1.912830031326255e-05,
            3.106610363928519e-05,
            6.078891992781161e-06,
            3.994812636560469e-06,
            9.618020076563406e-05,
            0.0008519888139760607,
            0.0006333468855152669,
            -0.0006844912802808009,
            0.0003617090995569217,
            0.0002406717940015195,
            -0.0008393663263009596,
            0.0011760448711963982,
            0.0005490627623284637,
            -0.00220874243480426,
            0.0008338814106919443,
            0.00012092582781410375,
            -0.0006225631306928346,
            0.0008661728790537889,
            0.0006728992977531895,
            -0.0016941351137028313,
            0.0011867290519552672,
            0.0006400643655888787,
            -0.0016915166611492036,
            0.0006738389706592196,
            0.00039634840627837675,
            -0.0007331199805097766,
            0.002519935332276716,
            0.0005919593132506624,
            -0.002318989353864015,
            -0.0008807309975861991,
            -0.0002800192587310308,
            0.00075911490224757,
            -0.0016729972827958448,
            -0.000712156942408613,
            0.001024395443478817,
            -0.0014345228722043705,
            -0.0001178214433784578,
            0.0016498587607745516,
            -0.0013040378698797725,
            -0.0010623881251014778,
            0.0018117490021968656,
            -0.0004674331359598256,
            -1.5136351674175687e-05,
            0.0019748253312311184,
            -9.012816754291495e-05,
            -0.00077421990764087,
            0.0014460930553892217,
            -0.0012653701888440255,
            -0.00032457181633432875,
            0.0011901866130469615,
            -0.0011189829231501008,
            -0.0008613524994033563,
            0.0011823589163089728,
            1.963320641083051e-05,
            -6.05495293438527e-05,
            1.537633218003134e-05,
            7.005883693809318e-05,
            8.786039133350597e-05,
            1.7493852473408934e-05,
            1.2965917086475778e-05,
            -4.905773511417019e-05,
            -0.00010919971516823848,
            -3.5354314539662796e-05,
            4.550735118499664e-05,
            5.925347665523122e-06,
            2.0911385217412558e-05,
            4.835658519002139e-05,
            -2.6902066654796636e-05,
            -0.0001918222814742011,
            4.079088094959686e-05,
            -3.05806596627172e-06,
            -3.2204416471703985e-05,
            0.0001017551297003803,
            2.1897351637282505e-05,
            -2.4886167514910484e-05,
            -2.590394621295273e-05,
            6.169677856286209e-05,
            -5.904558512207565e-05,
            -6.694275317879136e-05,
            -9.678279838199486e-05,
            8.582386073962004e-05,
            5.4370384214551596e-05,
            6.034189725993446e-06,
            4.478834671310214e-05,
            -2.6739603659235564e-05,
            5.0929635720557515e-06,
            -9.90449990212894e-05,
            -5.878396147024427e-06,
            -0.00011161907574761512,
            9.008343246956653e-05,
            5.490748248544623e-05,
            -4.175115721988108e-05,
            -0.0001615296250103654,
            -1.2325263831189185e-05,
            -1.627181911823892e-05,
            -7.075876763805016e-05,
            9.582615853141056e-05,
            -2.1825960727997125e-05,
            9.428417981388329e-05,
            2.0410556039145526e-05,
            4.82360997984623e-05,
        ]
        refm = [
            0.0017747708722387558,
            0.0008734317093440263,
            -0.003941535867109801,
            0.0026778848318010683,
            0.001594081295329827,
            -0.0027446203431385255,
            0.0011542037036953883,
            0.001664639499700188,
            -0.003557542944007189,
            0.0013748664546039513,
            0.002746800461636908,
            -0.0037013758368640848,
            0.0027219375943341524,
            0.001558944103669902,
            -0.0030775562303712646,
            0.0019195975414521105,
            0.0010410347865758,
            -0.004082613612995145,
            0.002950544420998806,
            0.0017443517389145893,
            -0.00280438589337985,
            0.0016295216822051065,
            0.0020122939866824346,
            -0.002235065559974328,
            -0.0014084486128318524,
            -0.0024318639050368847,
            0.002455859467921166,
            -0.002381357449118743,
            -0.0014102142077173374,
            0.0033896096799298126,
            -0.0022571934589191594,
            -0.002142732049459592,
            0.0030688128165551115,
            -0.0011657735881628135,
            -0.0024065865165099026,
            0.0032128164706444295,
            -0.0024664235335970217,
            -0.0007726386784343438,
            0.0037188543855119806,
            -0.0023823254322949666,
            -0.0006582201959793628,
            0.0033143021672394613,
            -0.0021343359058377345,
            -0.0021754729084252607,
            0.0026233865765973945,
            -0.0013689401880528937,
            -0.002474786190021163,
            0.0029101756601929963,
            0.0014727651708584858,
            0.0008409356648622745,
            -0.004142792939820731,
            0.0028828660587684103,
            0.0010756018791021834,
            -0.003773756254140926,
            0.0017197026580109253,
            0.0019573912403035667,
            -0.0035696831291771804,
            0.001107417577190393,
            0.002187856867570936,
            -0.004280990930326638,
            0.0008442668832378239,
            0.002385407575657181,
            -0.003901291119944071,
            0.0008045200452066648,
            0.0017771539361896918,
            -0.004077073901985023,
            0.0007150239888261852,
            0.0028356795012868157,
            -0.0036399129196079405,
            0.0014180701551646687,
            0.0009129090745171055,
            -0.00437886123106307,
            -0.0012625071071027325,
            -0.0016612396301565714,
            0.0046468539403522946,
            -0.0018856377137761915,
            -0.0005770302885891939,
            0.004564658617461026,
            -0.000962611628674113,
            -0.0026571784308159763,
            0.003162421540978592,
            -0.0008037651298011077,
            -0.002146347906925058,
            0.004287255280243266,
            -0.002417751850937123,
            -0.0012005656241931204,
            0.0029426540238182194,
            -0.000956602949653836,
            -0.002797424584849985,
            0.0037474653777991684,
            -0.0018087576133925206,
            -0.0008485083848328778,
            0.004796011130175016,
            -0.0018992698643625248,
            -0.0007015535942944564,
            0.004459188855221506,
        ]
        refe = np.reshape(refe, [-1])
        refr = np.reshape(refr, [-1])
        refm = np.reshape(refm, [-1])

        places = 10
        np.testing.assert_almost_equal(out_ener, refe, places)
        np.testing.assert_almost_equal(force_real, refr, places)
        np.testing.assert_almost_equal(force_mag, refm, places)


if __name__ == "__main__":
    unittest.main()
